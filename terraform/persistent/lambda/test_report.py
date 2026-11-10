# 로컬 자체 검사: python3 test_report.py (Lambda 에는 포함되지 않음 — archive 는 파일 1개씩)
import sys
import types

sys.modules.setdefault("boto3", types.ModuleType("boto3"))
import report  # noqa: E402

log = "\n".join(["2026-10-23T00:31:00.1234567Z step %d" % i for i in range(100)] + ["2026-10-23T00:40:00.0000000Z ##[error]Process completed with exit code 1."])
ex = report.log_excerpt(log)
assert ex[0] == "[오류 줄]" and ex[1] == "##[error]Process completed with exit code 1.", ex[:2]
assert ex[-1].startswith("##[error]") and len(ex) == 1 + 1 + 1 + 1 + report.LOG_LINES, len(ex)
assert not any("Z step" in ln for ln in ex), "타임스탬프 제거"

ok, msg = report.build_message("up", "2026-10-23T00:30:00.000Z", None, ["실행: x"], [(True, "EKS ACTIVE")])
assert ok and "AWS 켜기 성공" in msg and "10-23 09:30 KST" in msg, msg
ok, msg = report.build_message("down", "2026-10-23T10:00:00.000Z", {"Error": "States.Timeout", "Cause": "c"}, [], [(True, "남은 리소스 없음")])
assert not ok and "AWS 끄기 실패" in msg and "10-23 19:00 KST" in msg and "States.Timeout" in msg, msg
ok, _ = report.build_message("down", "2026-10-23T10:00:00.000Z", None, [], [(False, "남은 리소스: NAT x")])
assert not ok
# 대기 중 취소만 1번 다시 실행
T = {"Error": "States.Timeout", "Cause": "c"}
assert report.should_retry(T, None, "cancelled")
assert not report.should_retry(T, True, "cancelled"), "다시 실행은 1번만"
assert not report.should_retry({"Error": "WorkflowCancelled"}, None, "cancelled"), "시작 뒤 취소(사람)는 다시 실행 안 함"
assert not report.should_retry(T, None, None), "실행이 없거나 아직 대기 중이면 알림"
assert not report.should_retry(T, None, "failure")
assert not report.should_retry(None, None, "cancelled")
print("ok")
