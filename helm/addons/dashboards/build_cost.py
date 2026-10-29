# 비용 대시보드 생성기 — 단가를 바꾸면: python3 helm/addons/dashboards/build_cost.py helm/addons/dashboards/baedalsak-cost.json /dev/null
# 알림 식(helm/addons/kube-prometheus-stack.yaml grafana.alerting)도 같은 상수라 함께 수정
import json, sys
# 켜져 있는 동안 시간당 고정 단가 (USD, 크레딧 차감 전) — 2026-10-27 Cost Explorer 실측(9.5시간)으로 보정
FIXED = [
    ("Amazon MQ", 0.197), ("EKS 컨트롤 플레인", 0.100), ("NAT · 디스크 (EC2 기타)", 0.104),
    ("CloudWatch", 0.048), ("RDS", 0.028), ("ALB", 0.024), ("ElastiCache", 0.018),
    ("Secrets Manager", 0.013), ("공인 IPv4", 0.010), ("bastion", 0.0065), ("S3 · ECR · CloudTrail · 기타", 0.003),
]
NODE = 0.104  # t3.large 시간당
FIXED_SUM = round(sum(v for _, v in FIXED), 4)
HOURLY = f"({FIXED_SUM} + {NODE} * count(kube_node_info))"
TODAY = f"sum_over_time({HOURLY}[24h:1m]) / 60"
FORECAST = f"{TODAY} + {HOURLY} * clamp_min(9 - (hour() + minute() / 60), 0)"  # 18:00 KST = 09:00 UTC
PROM = {"type": "prometheus", "uid": "prometheus"}
CW = {"type": "cloudwatch", "uid": "cloudwatch"}

def stat(i, title, expr, x, w, unit="currencyUSD", steps=None, desc=""):
    return {"id": i, "type": "stat", "title": title, "description": desc, "datasource": PROM,
            "gridPos": {"h": 5, "w": w, "x": x, "y": 0},
            "targets": [{"refId": "A", "datasource": PROM, "expr": expr, "instant": True}],
            "fieldConfig": {"defaults": {"unit": unit, "decimals": 2, "thresholds": {"mode": "absolute", "steps": steps or [{"color": "green", "value": None}]}}, "overrides": []},
            "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "value", "graphMode": "none", "textMode": "value"}}

rows = " or ".join([f'label_replace(vector({v}), "item", "{n}", "", "")' for n, v in FIXED]
                   + [f'label_replace({NODE} * count(kube_node_info), "item", "EC2 노드 (t3.large × 노드 수)", "", "")'])

def cw(i, title, q, price, x, y, desc):
    return {"id": i, "type": "stat", "title": title, "description": desc, "datasource": {"type": "datasource", "uid": "-- Mixed --"},
            "gridPos": {"h": 5, "w": 6, "x": x, "y": y},
            "targets": [dict(refId="A", datasource=CW, region="default", queryMode="Metrics", metricQueryType=0, metricEditorMode=0,
                             id="", expression="", matchExact=False, period="3600", hide=True, **q),
                        {"refId": "B", "datasource": {"type": "__expr__", "uid": "__expr__"}, "type": "math", "expression": f"$A * {price}"}],
            "fieldConfig": {"defaults": {"unit": "currencyUSD", "decimals": 3}, "overrides": []},
            "options": {"reduceOptions": {"calcs": ["sum"]}, "colorMode": "none", "graphMode": "none", "textMode": "value"}}

panels = [
    stat(1, "지금 시간당 (추정)", HOURLY, 0, 6, steps=[{"color": "green", "value": None}, {"color": "orange", "value": 1}, {"color": "red", "value": 1.5}],
         desc="고정 단가 합 + t3.large × 노드 수. 평소 2노드 ≈ $0.76"),
    stat(2, "오늘 누적 (켜진 뒤부터)", TODAY, 6, 6, desc="Prometheus 는 켤 때 새로 시작 → 오늘 켜진 시각부터의 합"),
    stat(3, "오늘 예상 (18:00 까지 지금 속도)", FORECAST, 12, 6, steps=[{"color": "green", "value": None}, {"color": "orange", "value": 10}, {"color": "red", "value": 20}],
         desc="누적 + 지금 시간당 × 18:00 까지 남은 시간. $10 · $20 넘으면 메일"),
    stat(4, "노드 수", "count(kube_node_info)", 18, 6, unit="none", desc="Cluster Autoscaler 2~4대 — 늘면 대당 시간당 +$0.104"),
    {"id": 5, "type": "bargauge", "title": "항목별 시간당 (추정)", "datasource": PROM,
     "gridPos": {"h": 11, "w": 12, "x": 0, "y": 5},
     "targets": [{"refId": "A", "datasource": PROM, "expr": f"sort_desc({rows})", "instant": True, "legendFormat": "{{item}}"}],
     "fieldConfig": {"defaults": {"unit": "currencyUSD", "decimals": 3, "min": 0}, "overrides": []},
     "options": {"orientation": "horizontal", "displayMode": "basic", "reduceOptions": {"calcs": ["lastNotNull"]}, "showUnfilled": True}},
    {"id": 6, "type": "timeseries", "title": "시간당 비용 추이", "datasource": PROM,
     "gridPos": {"h": 11, "w": 12, "x": 12, "y": 5},
     "targets": [{"refId": "A", "datasource": PROM, "expr": HOURLY, "legendFormat": "시간당"}],
     "fieldConfig": {"defaults": {"unit": "currencyUSD", "decimals": 2, "min": 0}, "overrides": []}},
    cw(7, "RDS CPU 크레딧 초과 (오늘)", {"namespace": "AWS/RDS", "metricName": "CPUSurplusCreditsCharged", "statistic": "Sum", "dimensions": {}}, 0.075 / 60, 0, 16,
       "t4g 기준 성능 초과분. vCPU-분 크레딧 × $0.075/vCPU-시간"),
    cw(8, "NAT 전송 (오늘)", {"namespace": "AWS/NATGateway", "metricName": "BytesOutToDestination", "statistic": "Sum", "dimensions": {}}, 0.059 / 1073741824, 6, 16,
       "NAT 처리 GB × $0.059 (이미지 pull · 외부 API)"),
    cw(9, "ALB LCU (오늘)", {"namespace": "AWS/ApplicationELB", "metricName": "ConsumedLCUs", "statistic": "Average", "dimensions": {}}, 0.008, 12, 16,
       "시간당 평균 LCU × $0.008 (요청·연결 비례)"),
    cw(10, "SES 발송 (오늘)", {"namespace": "AWS/SES", "metricName": "Send", "statistic": "Sum", "dimensions": {}}, 0.0001, 18, 16,
       "메일 1통 $0.0001"),
    {"id": 11, "type": "text", "title": "설명", "gridPos": {"h": 6, "w": 24, "x": 0, "y": 21},
     "options": {"mode": "markdown", "content":
        "**추정치** — 실제 청구가 아니라 켜진 리소스 × 단가 (크레딧 차감 전, 10-27 실측 보정). 실제 금액은 매일 09:00 비용 메일 · Budgets 메일.\n\n"
        "- 위 4개 · 항목별 · 추이 = 고정 단가 + 노드 수 (Prometheus). 아래 4개 = 사용량 비례 추가분 (CloudWatch, 몇 분 늦음)\n"
        "- 알림: 오늘 예상 $10 · $20, 시간당 $1.5 초과 → SNS 알림 메일 (Grafana 알림, 5분마다 확인)\n"
        "- 단가는 `helm/addons/dashboards/baedalsak-cost.json` 생성 스크립트 기준 — 인스턴스 종류를 바꾸면 같이 수정"}},
]
dash = {"uid": "baedalsak-cost", "title": "배달싹 비용 (추정)", "tags": ["baedalsak", "cost"], "timezone": "browser",
        "schemaVersion": 39, "time": {"from": "now-12h", "to": "now"}, "refresh": "1m", "panels": panels}
json.dump(dash, open(sys.argv[1], "w"), ensure_ascii=False, indent=1)
open(sys.argv[2], "w").write(json.dumps({"HOURLY": HOURLY, "FORECAST": FORECAST, "FIXED_SUM": FIXED_SUM}, ensure_ascii=False))
print("fixed", FIXED_SUM, "→ 2노드", round(FIXED_SUM + 2 * NODE, 3))
