# 로컬 자체 검사: python3 test_cost_report.py (cost_report · notify, Lambda 에는 포함되지 않음 — archive 는 파일 1개씩)
import sys
import types
from datetime import date

sys.modules.setdefault("boto3", types.ModuleType("boto3"))
import cost_report  # noqa: E402

prev = [("Amazon EKS", 2.4), ("Amazon RDS", 4.8), ("Tax", 0.001)]
last = [("Amazon EKS", 1.0)]
subject, body = cost_report.build(date(2026, 10, 28), "baedalsak-prod", prev, last)
assert subject == "[배달싹] 일일 비용 2026-10-27 $7.20 · 2026-10-28(집계 중) $1.00", subject
assert "Amazon EKS" in body and "Tax" not in body, "0.00 달러 줄은 숨김"
assert body.index("2026-10-27") < body.index("2026-10-28"), "이틀 전 표가 먼저"
assert body.index("Amazon RDS") < body.index("합계") < body.index("2026-10-28"), "합계 줄은 각 표 맨 아래"
assert body.count("합계") == 2
print("ok")

# Discord 텍스트 (11-05)
text = cost_report.discord(date(2026, 10, 28), subject, prev, last)
assert text.startswith("**[배달싹] 일일 비용") and len(text) <= 2000
assert text.count("```") == 4 and "Tax" not in text and "$7.20" in text
long_rows = [(f"Service {i:02d} with a long long name", 1.0) for i in range(60)]
assert len(cost_report.discord(date(2026, 10, 28), subject, long_rows, long_rows)) <= 2000

import notify  # noqa: E402
parts = notify.chunks("\n".join(["x" * 300] * 20))
assert len(parts) > 1 and all(len(p) <= 2000 for p in parts) and sum(p.count("x") for p in parts) == 6000
assert notify._text('{"AlarmName": "a", "NewStateValue": "ALARM", "NewStateReason": "r"}') == "[ALARM] a\nr"
assert notify.chunks("") == []
ARN = "arn:aws:sns:ap-northeast-2:1:baedalsak-prod-"
assert notify.channel(ARN + "alerts", "[baedalsak-prod] AWS up FAILED") == "incident"
assert notify.channel(ARN + "alerts", "ALARM: \"baedalsak-prod-rds-cpu\" in Asia Pacific (Seoul)") == "incident"
G = "[baedalsak-prod] ALERT - 1 alert(s)"  # Grafana 제목 · 본문 "■ <규칙>" 줄로 구분
FOOT = "\n▶ 비용 대시보드 : https://x/d/baedalsak-cost"  # 모든 Grafana 본문 꼬리에 "비용" 이 있음
assert notify.channel(ARN + "alerts", G, "[알림 발생]\n■ 오늘 예상 비용 10달러 초과\n  내용 : x" + FOOT) == "cost"
assert notify.channel(ARN + "alerts", G, "■ 앱 ERROR 로그 급증  (order)" + FOOT) == "incident"
assert notify.channel(ARN + "alerts", G, "■ Argo CD 앱 Healthy 아님  (order · Degraded)" + FOOT) == "incident"
assert notify.channel(ARN + "alerts", G.replace("ALERT", "RESOLVED"), "■ MQ 메시지 처리 실패 (DLQ 가능)" + FOOT) == "incident"
assert notify.channel(ARN + "alerts", G, FOOT) == "incident"  # 규칙 줄이 없으면 장애 쪽으로 (놓치지 않게)
assert notify.channel(ARN + "alerts", "AWS Budgets: baedalsak-prod-daily has exceeded your alert threshold") == "cost"
assert notify.channel(ARN + "budget", "") == "cost"
print("discord ok")
