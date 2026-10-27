# 로컬 자체 검사: python3 test_cost_report.py (Lambda 에는 포함되지 않음 — archive 는 파일 1개씩)
import sys
import types
from datetime import date

sys.modules.setdefault("boto3", types.ModuleType("boto3"))
import cost_report  # noqa: E402

assert cost_report.tag_rows([("Stack$", 1.0)], "Stack") is None, "태그 값이 없으면 집계 전"
rows = cost_report.tag_rows([("Stack$ephemeral", 5.0), ("Stack$", 0.5)], "Stack")
assert rows == [("ephemeral", 5.0), ("(태그 없음)", 0.5)], rows

services = [("Amazon EKS", 2.4), ("Amazon RDS", 1.23), ("Tax", 0.001)]
subject, body = cost_report.build(date(2026, 10, 27), "baedalsak-prod", services, None, "Stack")
assert subject == "[배달싹] 2026-10-27 일일 비용 $3.63", subject
assert "Amazon EKS" in body and "Tax" not in body, "0.00 달러 줄은 숨김"
assert "집계 전" in body
_, body = cost_report.build(date(2026, 10, 27), "n", services, rows, "Stack")
assert "ephemeral" in body and "집계 전" not in body
print("ok")
