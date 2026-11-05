# Lambda ⑤ — SNS alerts·budget(알람 · 켜기/끄기 결과 · Grafana 비용 추정 · Budgets) 메시지를 Discord 웹훅으로 전달
#   웹훅 URL 은 Secrets Manager <SECRET_PREFIX>/discord-webhook (콘솔에서 넣음)
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


def send(text):
    url = boto3.client("secretsmanager").get_secret_value(SecretId=os.environ["DISCORD_WEBHOOK_SECRET"])["SecretString"].strip()
    for part in chunks(text):
        req = urllib.request.Request(url, data=json.dumps({"content": part}).encode(), method="POST",
                                     headers={"Content-Type": "application/json", "User-Agent": "baedalsak-notify"})
        urllib.request.urlopen(req, timeout=10).close()


def handler(event, _context):
    for record in event["Records"]:
        sns = record["Sns"]
        send(f"**{sns.get('Subject') or 'baedalsak 알림'}**\n{_text(sns['Message'])}")
