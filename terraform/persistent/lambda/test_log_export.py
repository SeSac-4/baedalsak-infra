# 로컬 자체 검사: python3 test_log_export.py (log_export, Lambda 에는 포함되지 않음)
import sys
import types
from datetime import datetime, timezone

sys.modules.setdefault("boto3", types.ModuleType("boto3"))
import log_export  # noqa: E402

# 03:00 KST(=전날 18:00 UTC) 실행 → 전날 KST 00:00~24:00
start, end = log_export.yesterday_kst(datetime(2026, 11, 13, 18, 0, tzinfo=timezone.utc))
assert start.isoformat() == "2026-11-13T00:00:00+09:00", start
assert end.isoformat() == "2026-11-14T00:00:00+09:00", end
assert int((end - start).total_seconds()) == 86400
assert list(log_export.targets("baedalsak-prod")) == ["/aws/rds/instance/baedalsak-prod/", "/aws/amazonmq/broker/"]
print("ok")
