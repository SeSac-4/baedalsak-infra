# Lambda ② — SNS(알람·켜기/끄기 결과·예산) 메시지를 Discord 웹훅으로 전달
import json
import os
import urllib.request

import boto3


def _text(message):
    try:
        m = json.loads(message)
    except ValueError:
        return message
    if "AlarmName" in m:  # CloudWatch 알람
        return f"[{m.get('NewStateValue')}] {m.get('AlarmName')}\n{m.get('NewStateReason', '')}"
    return json.dumps(m, ensure_ascii=False)[:1800]


def handler(event, _context):
    url = boto3.client("secretsmanager").get_secret_value(SecretId=os.environ["DISCORD_WEBHOOK_SECRET"])["SecretString"].strip()
    for record in event["Records"]:
        sns = record["Sns"]
        content = f"**{sns.get('Subject') or 'baedalsak 알림'}**\n{_text(sns['Message'])}"[:1900]  # Discord 한도 2000자
        req = urllib.request.Request(url, data=json.dumps({"content": content}).encode(), method="POST",
                                     headers={"Content-Type": "application/json", "User-Agent": "baedalsak-notify"})
        urllib.request.urlopen(req, timeout=10).close()
