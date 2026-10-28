# Lambda ② — 켜기·끄기가 끝난 뒤(성공·실패·시간 초과 모두) 결과를 확인해 메일(SNS alerts)로 보냄
#   ① GitHub 실행 찾기 (Step Functions 시작 시각 이후의 aws-up/aws-down 실행) → 실패한 job·step + 오류 로그
#   ② AWS 실제 상태 확인 — 켜기: EKS·노드그룹·RDS·사이트 응답 / 끄기: 비용이 나가는 리소스가 남았는지
#   반환 ok=false 면 Step Functions 가 실패로 끝남
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

import boto3

WORKFLOWS = {"up": "aws-up.yml", "down": "aws-down.yml"}
LABELS = {"up": "켜기", "down": "끄기"}
NAME = os.environ.get("NAME", "")
KST = timezone(timedelta(hours=9))
LOG_LINES = 40     # job 로그 마지막 줄 수
ERROR_LINES = 20   # ##[error] 줄 최대 수
MAX_MESSAGE = 60000


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None  # 로그는 302 → 서명된 저장소 URL. 토큰을 붙인 채 따라가지 않음


def _gh(path, token, raw=False):
    req = urllib.request.Request(f"https://api.github.com{path}", headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    try:
        with urllib.request.build_opener(_NoRedirect).open(req, timeout=20) as res:
            body = res.read()
    except urllib.error.HTTPError as e:
        if e.code not in (301, 302) or not raw:
            raise
        with urllib.request.urlopen(e.headers["Location"], timeout=30) as res:
            body = res.read()
    return body.decode("utf-8", "replace") if raw else json.loads(body)


def kst(iso):
    if not iso:
        return "-"
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(KST).strftime("%m-%d %H:%M")


def log_excerpt(text):
    """GitHub job 로그 → ##[error] 줄 + 마지막 LOG_LINES 줄 (앞의 타임스탬프 제거)"""
    lines = [re.sub(r"^\S+Z ", "", ln)[:300] for ln in text.splitlines()]
    errors = [ln for ln in lines if "##[error]" in ln][:ERROR_LINES]
    tail = lines[-LOG_LINES:]
    out = []
    if errors:
        out += ["[오류 줄]"] + errors + [""]
    return out + ["[마지막 %d줄]" % len(tail)] + tail


def github_section(action, started, token):
    repo, ref = os.environ["GITHUB_REPO"], os.environ["GITHUB_REF"]
    since = started[:19] + "Z"
    q = urllib.parse.urlencode({"branch": ref, "event": "workflow_dispatch", "created": f">={since}", "per_page": 5})
    runs = _gh(f"/repos/{repo}/actions/workflows/{WORKFLOWS[action]}/runs?{q}", token)["workflow_runs"]
    if not runs:
        return ["GitHub 실행 없음 — 워크플로가 시작되지 않음 (Lambda ① dispatch 실패 · 토큰 · 브랜치 확인)"]
    out = []
    for i, run in enumerate(reversed(runs[:2]), 1):  # Step Functions 재시도 시 실행 2개 (오래된 것부터)
        out += _run_lines(repo, run, token, f"{i}회차 " if len(runs) > 1 else "")
    return out


def _run_lines(repo, run, token, prefix):
    out = [f"{prefix}실행: {run['html_url']}",
           f"상태: {run['status']} / {run['conclusion'] or '-'} ({kst(run['run_started_at'])} ~ {kst(run['updated_at'])} KST)"]
    jobs = _gh(f"/repos/{repo}/actions/runs/{run['id']}/jobs?per_page=50", token)["jobs"]
    for job in jobs:
        if job["conclusion"] in ("success", "skipped"):
            continue
        steps = [s["name"] for s in job.get("steps", []) if s["conclusion"] not in ("success", "skipped", None)]
        running = [s["name"] for s in job.get("steps", []) if s["status"] == "in_progress"]
        out.append(f"막힌 곳: job '{job['name']}' ({job['status']}/{job['conclusion'] or '-'}) → step {steps or running or '-'}")
        if job["status"] == "completed":
            try:
                out += ["", f"--- 로그: {job['name']} ---"] + log_excerpt(_gh(f"/repos/{repo}/actions/jobs/{job['id']}/logs", token, raw=True))
            except Exception as e:  # 로그를 못 받아도 메일은 보냄
                out.append(f"(로그 받기 실패: {e})")
    return out + [""]


def _mine(names):
    return [n for n in names if n.startswith(NAME)]


def check_up():
    eks, rds = boto3.client("eks"), boto3.client("rds")
    clusters = _mine(eks.list_clusters()["clusters"])
    out = [] if clusters else [(False, "EKS 클러스터 없음")]
    for c in clusters:
        status = eks.describe_cluster(name=c)["cluster"]["status"]
        out.append((status == "ACTIVE", f"EKS {c} {status}"))
        for ng in eks.list_nodegroups(clusterName=c)["nodegroups"]:
            n = eks.describe_nodegroup(clusterName=c, nodegroupName=ng)["nodegroup"]
            out.append((n["status"] == "ACTIVE", f"노드그룹 {ng} {n['status']} (노드 {n['scalingConfig']['desiredSize']}대)"))
    dbs = [d for d in rds.describe_db_instances()["DBInstances"] if d["DBInstanceIdentifier"].startswith(NAME)]
    out += [(d["DBInstanceStatus"] == "available", f"RDS {d['DBInstanceIdentifier']} {d['DBInstanceStatus']}") for d in dbs] or [(False, "RDS 없음")]
    url = f"https://{os.environ['DOMAIN_NAME']}/api/v1/stores"
    try:
        with urllib.request.urlopen(url, timeout=15) as res:
            code = res.status
    except urllib.error.HTTPError as e:
        code = e.code
    except Exception as e:
        code = f"연결 실패 {e}"
    out.append((isinstance(code, int) and code not in (502, 503, 504), f"사이트 {url} → {code}"))
    return out


def check_down():
    """남아 있으면 비용이 나가는 ephemeral 리소스"""
    ec2 = boto3.client("ec2")
    left = []
    left += [f"EKS {c}" for c in _mine(boto3.client("eks").list_clusters()["clusters"])]
    left += [f"RDS {d['DBInstanceIdentifier']}" for d in boto3.client("rds").describe_db_instances()["DBInstances"] if d["DBInstanceIdentifier"].startswith(NAME)]
    left += [f"MQ {b['BrokerName']}" for b in boto3.client("mq").list_brokers()["BrokerSummaries"] if b["BrokerName"].startswith(NAME)]
    left += [f"ElastiCache {g['ReplicationGroupId']}" for g in boto3.client("elasticache").describe_replication_groups()["ReplicationGroups"] if g["ReplicationGroupId"].startswith(NAME)]
    left += [f"ALB {lb['LoadBalancerName']}" for lb in boto3.client("elbv2").describe_load_balancers()["LoadBalancers"] if lb["LoadBalancerName"].startswith(NAME)]
    left += [f"NAT {n['NatGatewayId']} ({n['State']})" for n in ec2.describe_nat_gateways(Filters=[{"Name": "state", "Values": ["pending", "available"]}])["NatGateways"]]
    for r in ec2.describe_instances(Filters=[{"Name": "instance-state-name", "Values": ["pending", "running", "stopping"]}])["Reservations"]:
        left += [f"EC2 {i['InstanceId']} {i['InstanceType']}" for i in r["Instances"]]
    dists = boto3.client("cloudfront").list_distributions()["DistributionList"].get("Items", [])
    left += [f"CloudFront {d['Id']}" for d in dists if d.get("Comment") == NAME]
    return [(False, f"남은 리소스: {x}") for x in left] or [(True, "남은 리소스 없음 (EKS·RDS·MQ·ElastiCache·ALB·NAT·EC2·CloudFront)")]


def build_message(action, started, error, gh_lines, checks):
    ok = error is None and all(c[0] for c in checks)
    lines = [f"AWS {LABELS[action]} {'성공' if ok else '실패'} — Step Functions 시작 {kst(started)} KST", ""]
    if error:
        lines += [f"Step Functions 오류: {error.get('Error')}", f"원인: {str(error.get('Cause'))[:2000]}", ""]
    lines += ["[AWS 상태 확인]"] + [("OK  " if c[0] else "XX  ") + c[1] for c in checks] + ["", "[GitHub Actions]"] + gh_lines
    return ok, "\n".join(lines)[:MAX_MESSAGE]


def handler(event, _context):
    inp = event["input"]
    action, started, error = inp["action"], event["started"], inp.get("error")
    try:
        token = boto3.client("secretsmanager").get_secret_value(SecretId=os.environ["GITHUB_TOKEN_SECRET"])["SecretString"].strip()
        gh_lines = github_section(action, started, token)
    except Exception as e:
        gh_lines = [f"GitHub 조회 실패: {e}"]
    try:
        checks = check_up() if action == "up" else check_down()
    except Exception as e:
        checks = [(False, f"AWS 상태 확인 실패: {e}")]
    ok, message = build_message(action, started, error, gh_lines, checks)
    # 성공은 메일 없이 Step Functions·Lambda 로그로만 남김 (실패만 알림). SNS 메일 제목은 ASCII 만 허용
    if not ok:
        boto3.client("sns").publish(TopicArn=os.environ["TOPIC_ARN"], Subject=f"[{NAME}] AWS {action} FAILED", Message=message)
    return {"ok": ok}
