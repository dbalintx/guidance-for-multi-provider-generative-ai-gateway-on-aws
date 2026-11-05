"""Collect the gateway's server-side metrics for a load-test window.

  python collect_metrics.py --cluster <deployment>-cluster --service <deployment>-litellm \
      --alb-arn-suffix app/<alb>/<id> --target-group-arn-suffix targetgroup/<tg>/<id> \
      --start 2026-01-01T10:00:00Z --end 2026-01-01T11:00:00Z --out results/<run>/server

Writes, per minute:
  tasks.csv     per task: CPU % of the task reservation, memory MiB and % (Container Insights)
  service.csv   service CPU/memory average and maximum (AWS/ECS, what target tracking uses),
                running/desired task count, ALB requests, 5xx/502/503/504, target response time
  scaling.txt   Application Auto Scaling activities in the window
Read-only: CloudWatch Logs Insights, GetMetricData, DescribeScalingActivities.
The app outputs ecs_cluster_name, ecs_service_name, alb_arn_suffix and
target_group_arn_suffix give the identifiers.
"""

from __future__ import annotations

import argparse
import csv
import os
import time
from datetime import UTC, datetime

import boto3


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(UTC)


def task_metrics(logs, cluster: str, service: str, start: datetime, end: datetime) -> list[dict]:
    query = f"""
fields @timestamp
| filter Type = "Task" and ServiceName = "{service}"
| stats avg(CpuUtilized / CpuReserved * 100) as cpu_pct, max(MemoryUtilized) as mem_mib,
        max(MemoryUtilized / MemoryReserved * 100) as mem_pct by bin(1m) as minute, TaskId
| sort minute asc
| limit 10000
"""
    qid = logs.start_query(
        logGroupName=f"/aws/ecs/containerinsights/{cluster}/performance",
        startTime=int(start.timestamp()),
        endTime=int(end.timestamp()),
        queryString=query,
    )["queryId"]
    while True:
        result = logs.get_query_results(queryId=qid)
        if result["status"] in ("Complete", "Failed", "Cancelled", "Timeout"):
            break
        time.sleep(2)
    if result["status"] != "Complete":
        raise RuntimeError(f"Logs Insights query {result['status']}")
    rows = [{f["field"]: f["value"] for f in row} for row in result["results"]]
    return [
        {
            "minute": r["minute"][:16],
            "task": r["TaskId"][:8],
            "cpu_pct": round(float(r["cpu_pct"]), 1),
            "mem_mib": int(float(r["mem_mib"])),
            "mem_pct": round(float(r["mem_pct"]), 1),
        }
        for r in rows
    ]


def service_metrics(cw, cluster, service, alb, tg, start, end) -> list[dict]:
    svc = [{"Name": "ClusterName", "Value": cluster}, {"Name": "ServiceName", "Value": service}]
    lb = [{"Name": "LoadBalancer", "Value": alb}]
    lbtg = lb + [{"Name": "TargetGroup", "Value": tg}]
    specs = {
        "cpu_avg": ("AWS/ECS", "CPUUtilization", svc, "Average"),
        "cpu_max": ("AWS/ECS", "CPUUtilization", svc, "Maximum"),
        "mem_avg": ("AWS/ECS", "MemoryUtilization", svc, "Average"),
        "mem_max": ("AWS/ECS", "MemoryUtilization", svc, "Maximum"),
        "running": ("ECS/ContainerInsights", "RunningTaskCount", svc, "Average"),
        "desired": ("ECS/ContainerInsights", "DesiredTaskCount", svc, "Average"),
        "requests": ("AWS/ApplicationELB", "RequestCount", lbtg, "Sum"),
        "elb_5xx": ("AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", lb, "Sum"),
        "elb_502": ("AWS/ApplicationELB", "HTTPCode_ELB_502_Count", lb, "Sum"),
        "elb_503": ("AWS/ApplicationELB", "HTTPCode_ELB_503_Count", lb, "Sum"),
        "elb_504": ("AWS/ApplicationELB", "HTTPCode_ELB_504_Count", lb, "Sum"),
        "target_5xx": ("AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", lbtg, "Sum"),
        "target_conn_err": ("AWS/ApplicationELB", "TargetConnectionErrorCount", lbtg, "Sum"),
        "healthy_hosts": ("AWS/ApplicationELB", "HealthyHostCount", lbtg, "Minimum"),
        "trt_p95_s": ("AWS/ApplicationELB", "TargetResponseTime", lbtg, "p95"),
    }
    queries = [
        {
            "Id": key,
            "MetricStat": {
                "Metric": {"Namespace": ns, "MetricName": name, "Dimensions": dims},
                "Period": 60,
                "Stat": stat,
            },
        }
        for key, (ns, name, dims, stat) in specs.items()
    ]
    series: dict[str, dict[datetime, float]] = {k: {} for k in specs}
    kwargs = {"MetricDataQueries": queries, "StartTime": start, "EndTime": end}
    while True:
        resp = cw.get_metric_data(**kwargs)
        for r in resp["MetricDataResults"]:
            series[r["Id"]].update(zip(r["Timestamps"], r["Values"], strict=True))
        if not resp.get("NextToken"):
            break
        kwargs["NextToken"] = resp["NextToken"]
    minutes = sorted({t for s in series.values() for t in s})
    rows = []
    for t in minutes:
        row = {"minute": t.astimezone(UTC).strftime("%Y-%m-%d %H:%M")}
        for key in specs:
            v = series[key].get(t)
            row[key] = "" if v is None else round(v, 3 if key == "trt_p95_s" else 1)
        rows.append(row)
    return rows


def scaling_activities(aas, cluster, service, start, end) -> list[str]:
    out = []
    paginator = aas.get_paginator("describe_scaling_activities")
    for page in paginator.paginate(ServiceNamespace="ecs", ResourceId=f"service/{cluster}/{service}"):
        for a in page["ScalingActivities"]:
            if start <= a["StartTime"] <= end:
                when = a["StartTime"].astimezone(UTC)
                out.append(f"{when:%Y-%m-%d %H:%M:%S} {a['StatusCode']}: {a['Description']} ({a.get('Cause', '')})")
    return sorted(out)


def write_csv(path: str, rows: list[dict]) -> None:
    if not rows:
        open(path, "w").close()
        return
    with open(path, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--cluster", required=True)
    p.add_argument("--service", required=True)
    p.add_argument("--alb-arn-suffix", required=True)
    p.add_argument("--target-group-arn-suffix", required=True)
    p.add_argument("--start", required=True, type=parse_time)
    p.add_argument("--end", required=True, type=parse_time)
    p.add_argument("--out", required=True)
    a = p.parse_args()
    os.makedirs(a.out, exist_ok=True)
    write_csv(
        os.path.join(a.out, "tasks.csv"), task_metrics(boto3.client("logs"), a.cluster, a.service, a.start, a.end)
    )
    write_csv(
        os.path.join(a.out, "service.csv"),
        service_metrics(
            boto3.client("cloudwatch"),
            a.cluster,
            a.service,
            a.alb_arn_suffix,
            a.target_group_arn_suffix,
            a.start,
            a.end,
        ),
    )
    with open(os.path.join(a.out, "scaling.txt"), "w") as fh:
        fh.write(
            "\n".join(scaling_activities(boto3.client("application-autoscaling"), a.cluster, a.service, a.start, a.end))
            + "\n"
        )
    print(a.out)


if __name__ == "__main__":
    main()
