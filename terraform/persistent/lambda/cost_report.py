# Lambda ④ — 이틀 전(확정에 가까움)·전날(집계 중) 하루 비용(크레딧·환불 차감 전)을 서비스별 표로 SES 메일 발송 (매일 09:00 KST)
#   Cost Explorer 는 하루 가까이 늦게 집계 → 전날 값은 실제보다 적게 나옴 (10-28: 메일 $3.29, 실제 약 $7)
import html
import json
import os
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


def handler(event, _context):
    day = (datetime.now(KST) - timedelta(days=1)).date()
    ce = boto3.client("ce", region_name="us-east-1")  # Cost Explorer 는 us-east-1 엔드포인트
    subject, body = build(day, os.environ["NAME"], fetch(ce, day - timedelta(days=1)), fetch(ce, day))
    boto3.client("sesv2").send_email(
        FromEmailAddress=os.environ["SENDER"],
        Destination={"ToAddresses": json.loads(os.environ["RECIPIENTS"])},
        Content={"Simple": {"Subject": {"Data": subject, "Charset": "UTF-8"}, "Body": {"Html": {"Data": body, "Charset": "UTF-8"}}}},
    )
    return {"subject": subject}
