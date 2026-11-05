# Lambda ⑤ — SNS alerts·budget 메시지를 Discord 웹훅으로 전달 (채널 2개)
#   incident : CloudWatch 알람 · 켜기/끄기 실패      cost : Budgets · Grafana 비용 추정
#   웹훅은 Secrets Manager <SECRET_PREFIX>/discord-webhook = {"incident": "<URL>", "cost": "<URL>"} (URL 하나만 넣으면 둘 다 그 채널)
import json
import os
import urllib.request

import boto3

LIMIT = 1900  # Discord content 한도 2000자


def _text(message):
    try:
        m = json.loads(message)
    except ValueError:
        return message
    if "AlarmName" in m:  # CloudWatch 알람
        return f"[{m.get('NewStateValue')}] {m.get('AlarmName')}\n{m.get('NewStateReason', '')}"
    return json.dumps(m, ensure_ascii=False, indent=1)


def chunks(text):
    """긴 메시지(켜기/끄기 실패 로그)는 줄 단위로 나눠 여러 번 보냄"""
    out, cur = [], ""
    for line in text.splitlines():
        line = line[:LIMIT]
        if len(cur) + len(line) + 1 > LIMIT:
            out.append(cur)
            cur = ""
        cur += line + "\n"
    return out + [cur] if cur.strip() else out


def webhook(kind):
    value = boto3.client("secretsmanager").get_secret_value(SecretId=os.environ["DISCORD_WEBHOOK_SECRET"])["SecretString"].strip()
    return json.loads(value)[kind] if value.startswith("{") else value


def channel(topic_arn, subject):
    # shortcut: Grafana 알림 규칙이 지금 전부 비용(그룹 cost)이라 Grafana 제목 형식이면 cost — 비용 외 Grafana 규칙을 추가하면 제목으로 구분하게 바꿀 것
    grafana = " ALERT - " in subject or " RESOLVED - " in subject
    return "cost" if topic_arn.endswith("-budget") or "Budget" in subject or grafana else "incident"


def send(text, kind="incident"):
    url = webhook(kind)
    for part in chunks(text):
        req = urllib.request.Request(url, data=json.dumps({"content": part}).encode(), method="POST",
                                     headers={"Content-Type": "application/json", "User-Agent": "baedalsak-notify"})
        urllib.request.urlopen(req, timeout=10).close()


def handler(event, _context):
    for record in event["Records"]:
        sns = record["Sns"]
        subject = sns.get("Subject") or ""
        send(f"**{subject or 'baedalsak 알림'}**\n{_text(sns['Message'])}", channel(sns.get("TopicArn", ""), subject))
