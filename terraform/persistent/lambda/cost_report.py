# Lambda ④ — 이틀 전(확정에 가까움)·전날(집계 중) 하루 비용(크레딧·환불 차감 전)을 서비스별 표로 Discord(+ ALERT_EMAILS 있으면 SES 메일) 발송 (매일 09:00 KST)
#   Cost Explorer 는 하루 가까이 늦게 집계 → 전날 값은 실제보다 적게 나옴 (10-28: 메일 $3.29, 실제 약 $7)
import html
import json
import os
import urllib.request
from datetime import datetime, timedelta, timezone

import boto3

KST = timezone(timedelta(hours=9))


def fetch(ce, day):
    res = ce.get_cost_and_usage(
        TimePeriod={"Start": day.isoformat(), "End": (day + timedelta(days=1)).isoformat()},
        Granularity="DAILY",
        Metrics=["UnblendedCost"],
        # 크레딧·환불 제외 → 실제 사용 금액
        Filter={"Not": {"Dimensions": {"Key": "RECORD_TYPE", "Values": ["Credit", "Refund"]}}},
        GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
    )
    rows = [(g["Keys"][0], float(g["Metrics"]["UnblendedCost"]["Amount"])) for g in res["ResultsByTime"][0]["Groups"]]
    return sorted(rows, key=lambda r: -r[1])


def table(title, rows):
    total = sum(v for _, v in rows)
    body = "".join(
        f"<tr><td>{html.escape(name)}</td><td style='text-align:right'>${v:,.2f}</td><td style='text-align:right'>{(v / total * 100 if total else 0):.1f}%</td></tr>"
        for name, v in rows if round(v, 2) > 0
    )
    foot = f"<tr><th>합계</th><th style='text-align:right'>${total:,.2f}</th><th style='text-align:right'>100%</th></tr>"
    return total, f"<h3>{html.escape(title)}</h3><table border='1' cellpadding='4' cellspacing='0'><tr><th>항목</th><th>금액</th><th>비율</th></tr>{body}{foot}</table>"


def build(day, name, prev_rows, last_rows):
    prev = day - timedelta(days=1)
    prev_total, prev_html = table(f"① {prev.isoformat()} (이틀 전 · 확정에 가까움)", prev_rows)
    last_total, last_html = table(f"② {day.isoformat()} (전날 · 집계 중이라 적게 나올 수 있음)", last_rows)
    subject = f"[배달싹] 일일 비용 {prev.isoformat()} ${prev_total:,.2f} · {day.isoformat()}(집계 중) ${last_total:,.2f}"
    body = f"<p>{html.escape(name)} · UTC 하루 기준 · 크레딧·환불 차감 전 금액</p>" + prev_html + last_html
    return subject, body


def text_table(title, rows):
    total = sum(v for _, v in rows)
    lines = [f"{name[:34]:<34} {f'${v:,.2f}':>9} {(v / total * 100 if total else 0):5.1f}%" for name, v in rows if round(v, 2) > 0]
    return f"**{title}**\n```\n" + "\n".join(lines + [f"{'합계':<33} {f'${total:,.2f}':>9}  100%"]) + "\n```"


def discord(day, subject, prev_rows, last_rows):
    """Discord 용 텍스트 (content 2000자 한도 — 서비스 수가 많으면 표 줄을 자름)"""
    prev = day - timedelta(days=1)
    text = "\n".join([f"**{subject}**", "UTC 하루 기준 · 크레딧·환불 차감 전 금액",
                      text_table(f"① {prev.isoformat()} (이틀 전 · 확정에 가까움)", prev_rows[:20]),
                      text_table(f"② {day.isoformat()} (전날 · 집계 중이라 적게 나올 수 있음)", last_rows[:20])])
    return text[:1990]


def post_discord(text):
    url = boto3.client("secretsmanager").get_secret_value(SecretId=os.environ["DISCORD_WEBHOOK_SECRET"])["SecretString"].strip()
    req = urllib.request.Request(url, data=json.dumps({"content": text}).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "User-Agent": "baedalsak-cost-report"})
    urllib.request.urlopen(req, timeout=10).close()


def handler(event, _context):
    day = (datetime.now(KST) - timedelta(days=1)).date()
    ce = boto3.client("ce", region_name="us-east-1")  # Cost Explorer 는 us-east-1 엔드포인트
    prev_rows, last_rows = fetch(ce, day - timedelta(days=1)), fetch(ce, day)
    subject, body = build(day, os.environ["NAME"], prev_rows, last_rows)
    post_discord(discord(day, subject, prev_rows, last_rows))
    recipients = json.loads(os.environ["RECIPIENTS"])
    if recipients:  # 메일은 ALERT_EMAILS 가 있을 때만 (11-05: Discord 로 전환, 메일 코드는 유지)
        boto3.client("sesv2").send_email(
            FromEmailAddress=os.environ["SENDER"],
            Destination={"ToAddresses": recipients},
            Content={"Simple": {"Subject": {"Data": subject, "Charset": "UTF-8"}, "Body": {"Html": {"Data": body, "Charset": "UTF-8"}}}},
        )
    return {"subject": subject}
