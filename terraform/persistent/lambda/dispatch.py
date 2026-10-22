# Lambda ① — Step Functions 작업 토큰을 받아 GitHub Actions 켜기/끄기 워크플로를 실행
#   워크플로 마지막 단계가 같은 토큰으로 send-task-success/failure 를 보내 결과를 돌려줌
import json
import os
import urllib.request

import boto3

WORKFLOWS = {"up": "aws-up.yml", "down": "aws-down.yml"}


def handler(event, _context):
    action = event["action"]
    if action not in WORKFLOWS:
        raise ValueError(f"unknown action: {action}")
    token = boto3.client("secretsmanager").get_secret_value(SecretId=os.environ["GITHUB_TOKEN_SECRET"])["SecretString"].strip()
    url = f"https://api.github.com/repos/{os.environ['GITHUB_REPO']}/actions/workflows/{WORKFLOWS[action]}/dispatches"
    body = json.dumps({"ref": os.environ["GITHUB_REF"], "inputs": {"task_token": event["token"]}}).encode()
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    with urllib.request.urlopen(req, timeout=15) as res:  # 204 가 정상, 그 밖은 HTTPError 로 실패 → Step Functions 재시도
        return {"status": res.status, "workflow": WORKFLOWS[action]}
