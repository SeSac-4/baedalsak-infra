# Lambda ③ — Budgets 초과 알림(SNS)을 받으면 끄기(Step Functions action=down) 실행
import json
import os

import boto3


def handler(event, _context):
    sfn = boto3.client("stepfunctions")
    res = sfn.start_execution(stateMachineArn=os.environ["STATE_MACHINE_ARN"], input=json.dumps({"action": "down", "reason": "budget"}))
    return {"executionArn": res["executionArn"]}
