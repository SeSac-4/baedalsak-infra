# 로컬 자체 검사: python3 test_cost_report.py (Lambda 에는 포함되지 않음 — archive 는 파일 1개씩)
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
