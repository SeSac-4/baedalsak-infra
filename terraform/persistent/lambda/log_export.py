# Lambda ⑥ — 매일 03:00 KST: RDS · Amazon MQ 로그 그룹 보존을 14일로 맞추고, 전날(KST 00:00~24:00) 로그를 S3 로그 버킷으로 내보냄
#   두 로그 그룹 모두 서비스가 직접 만들어 보존 기간이 "무기한" → 여기서 14일로 바꿈
#   MQ 는 브로커를 매일 새로 만들어 로그 그룹 이름(/aws/amazonmq/broker/<브로커 ID>/general)이 매일 바뀜 → 접두사로 찾음
#   CloudWatch 내보내기는 계정당 동시에 1건만 됨 → 하나씩 끝날 때까지 기다림
#   S3: <버킷>/rds|mq/<날짜>/<로그 그룹>/<작업 ID>/<스트림>/000000.gz
import os
import time
from datetime import datetime, timedelta, timezone

import boto3

KST = timezone(timedelta(hours=9))
RETENTION_DAYS = 14


def yesterday_kst(now):
    end = now.astimezone(KST).replace(hour=0, minute=0, second=0, microsecond=0)
    return end - timedelta(days=1), end


def targets(name):
    return {f"/aws/rds/instance/{name}/": "rds", "/aws/amazonmq/broker/": "mq"}


def has_events(logs, group, start_ms):
    streams = logs.describe_log_streams(logGroupName=group, orderBy="LastEventTime", descending=True, limit=1)["logStreams"]
    return bool(streams) and streams[0].get("lastEventTimestamp", 0) >= start_ms


def wait(logs, task_id, deadline):
    while time.time() < deadline:
        status = logs.describe_export_tasks(taskId=task_id)["exportTasks"][0]["status"]["code"]
        if status in ("COMPLETED", "FAILED", "CANCELLED"):
            return status
        time.sleep(5)
    raise TimeoutError(f"내보내기 {task_id} 가 시간 안에 끝나지 않음")


def handler(event, context):
    logs = boto3.client("logs")
    bucket = os.environ["BUCKET"]
    start, end = yesterday_kst(datetime.now(timezone.utc))
    start_ms, end_ms = int(start.timestamp() * 1000), int(end.timestamp() * 1000)
    deadline = time.time() + context.get_remaining_time_in_millis() / 1000 - 30
    result = []
    for prefix, dest in targets(os.environ["NAME"]).items():
        for page in logs.get_paginator("describe_log_groups").paginate(logGroupNamePrefix=prefix):
            for g in page["logGroups"]:
                group = g["logGroupName"]
                if g.get("retentionInDays") != RETENTION_DAYS:
                    logs.put_retention_policy(logGroupName=group, retentionInDays=RETENTION_DAYS)
                if not has_events(logs, group, start_ms):
                    continue
                task_id = logs.create_export_task(
                    taskName=f"{dest}-{start:%Y%m%d}",
                    logGroupName=group,
                    fromTime=start_ms,
                    to=end_ms,
                    destination=bucket,
                    destinationPrefix=f"{dest}/{start:%Y-%m-%d}{group}",
                )["taskId"]
                result.append((group, wait(logs, task_id, deadline)))
    print(result)
    failed = [r for r in result if r[1] != "COMPLETED"]
    if failed:
        raise RuntimeError(f"내보내기 실패: {failed}")  # Lambda 오류 → CloudWatch 지표 Errors
    return {"exported": len(result)}
