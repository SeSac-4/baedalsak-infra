# Lambda ④ — 전날 하루 비용(크레딧·환불 차감 전)을 서비스별·스택 태그별 표로 SES 메일 발송 (매일 09:00 KST)
import html
import json
import os
from datetime import datetime, timedelta, timezone

import boto3

KST = timezone(timedelta(hours=9))


def fetch(ce, day, group_by):
    start = day.isoformat()
    end = (day + timedelta(days=1)).isoformat()
    res = ce.get_cost_and_usage(
        TimePeriod={"Start": start, "End": end},
        Granularity="DAILY",
        Metrics=["UnblendedCost"],
        # 크레딧·환불 제외 → 실제 사용 금액
        Filter={"Not": {"Dimensions": {"Key": "RECORD_TYPE", "Values": ["Credit", "Refund"]}}},
        GroupBy=[group_by],
    )
    rows = []
    for g in res["ResultsByTime"][0]["Groups"]:
        rows.append((g["Keys"][0], float(g["Metrics"]["UnblendedCost"]["Amount"])))
    return sorted(rows, key=lambda r: -r[1])


def tag_rows(rows, tag_key):
    # 태그 그룹 키는 "<키>$<값>", 태그 없는 비용은 "<키>$" → 값이 하나도 없으면 집계 전(비용 할당 태그 활성화 전)
    out = [(k.split("$", 1)[1] or "(태그 없음)", v) for k, v in rows]
    return out if any(name != "(태그 없음)" for name, _ in out) else None


def table(title, rows, total):
    body = "".join(
        f"<tr><td>{html.escape(name)}</td><td style='text-align:right'>${v:,.2f}</td><td style='text-align:right'>{(v / total * 100 if total else 0):.1f}%</td></tr>"
        for name, v in rows if round(v, 2) > 0
    )
    return f"<h3>{html.escape(title)}</h3><table border='1' cellpadding='4' cellspacing='0'><tr><th>항목</th><th>금액</th><th>비율</th></tr>{body}</table>"


def build(day, name, services, tags, tag_key):
    total = sum(v for _, v in services)
    subject = f"[배달싹] {day.isoformat()} 일일 비용 ${total:,.2f}"
    tag_html = table(f"② 스택 태그별 ({tag_key})", tags, total) if tags else f"<h3>② 스택 태그별 ({html.escape(tag_key)})</h3><p>집계 전 — 비용 할당 태그 활성화 후 하루 이상 지나야 보입니다.</p>"
    body = (
        f"<p>{html.escape(name)} · {day.isoformat()} (UTC 하루) · 크레딧·환불 차감 전 금액</p>"
        + table("① 서비스별", services, total)
        + tag_html
    )
    return subject, body


def handler(event, _context):
    day = (datetime.now(KST) - timedelta(days=1)).date()
    ce = boto3.client("ce", region_name="us-east-1")  # Cost Explorer 는 us-east-1 엔드포인트
    tag_key = os.environ["TAG_KEY"]
    services = fetch(ce, day, {"Type": "DIMENSION", "Key": "SERVICE"})
    tags = tag_rows(fetch(ce, day, {"Type": "TAG", "Key": tag_key}), tag_key)
    subject, body = build(day, os.environ["NAME"], services, tags, tag_key)
    boto3.client("sesv2").send_email(
        FromEmailAddress=os.environ["SENDER"],
        Destination={"ToAddresses": json.loads(os.environ["RECIPIENTS"])},
        Content={"Simple": {"Subject": {"Data": subject, "Charset": "UTF-8"}, "Body": {"Html": {"Data": body, "Charset": "UTF-8"}}}},
    )
    return {"subject": subject}
