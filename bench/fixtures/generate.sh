#!/bin/sh
# Regenerates medium.yaml and large.yaml. Output is fully deterministic
# (no timestamps, no randomness), so reruns are byte-identical.
set -eu
cd "$(dirname "$0")"

# medium.yaml: a Kubernetes-style multi-document manifest - Deployments,
# Services, and ConfigMaps with nested metadata, label maps, container
# specs, and many short strings. Targets ~20 KB.
awk 'BEGIN {
  n = 12
  for (i = 0; i < n; i++) {
    app = sprintf("svc-%02d", i)
    replicas = 1 + (i % 5)
    port = 8000 + i * 11
    if (i > 0) printf "---\n"
    printf "apiVersion: apps/v1\n"
    printf "kind: Deployment\n"
    printf "metadata:\n"
    printf "  name: %s\n", app
    printf "  namespace: team-%d\n", i % 3
    printf "  labels:\n"
    printf "    app: %s\n", app
    printf "    tier: %s\n", (i % 2 == 0 ? "backend" : "frontend")
    printf "    managed-by: platform\n"
    printf "  annotations:\n"
    printf "    config.example.com/checksum: \"%08x\"\n", i * 2654435761
    printf "    config.example.com/owner: team-%d@example.com\n", i % 3
    printf "spec:\n"
    printf "  replicas: %d\n", replicas
    printf "  selector:\n"
    printf "    matchLabels:\n"
    printf "      app: %s\n", app
    printf "  template:\n"
    printf "    metadata:\n"
    printf "      labels:\n"
    printf "        app: %s\n", app
    printf "        version: v%d.%d.%d\n", i % 4, (i * 3) % 10, (i * 7) % 10
    printf "    spec:\n"
    printf "      containers:\n"
    c = 1 + (i % 3)
    for (k = 0; k < c; k++) {
      printf "        - name: %s-container-%d\n", app, k
      printf "          image: registry.example.com/%s:%d.%d.%d\n", app, i % 4, k, (i + k) % 10
      printf "          imagePullPolicy: IfNotPresent\n"
      printf "          ports:\n"
      printf "            - containerPort: %d\n", port + k
      printf "              protocol: TCP\n"
      printf "          env:\n"
      printf "            - name: LOG_LEVEL\n"
      printf "              value: %s\n", (i % 2 == 0 ? "info" : "debug")
      printf "            - name: MAX_WORKERS\n"
      printf "              value: \"%d\"\n", 2 + (i % 8)
      printf "            - name: REGION\n"
      printf "              value: %s\n", (i % 2 == 0 ? "us-east-1" : "eu-west-1")
      printf "          resources:\n"
      printf "            requests:\n"
      printf "              cpu: %dm\n", 100 + i * 25
      printf "              memory: %dMi\n", 128 + i * 32
      printf "            limits:\n"
      printf "              cpu: %dm\n", 500 + i * 50
      printf "              memory: %dMi\n", 512 + i * 64
      printf "          readinessProbe:\n"
      printf "            httpGet:\n"
      printf "              path: /healthz\n"
      printf "              port: %d\n", port + k
      printf "            initialDelaySeconds: %d\n", 5 + (i % 10)
      printf "            periodSeconds: 10\n"
    }
  }
}' > medium.yaml

# large.yaml: a flat sequence of 1000 records mixing strings, ints,
# floats, bools, nulls, nested maps, and small flow sequences. Targets
# ~150 KB.
awk 'BEGIN {
  n = 1000
  for (i = 0; i < n; i++) {
    printf "- id: %d\n", 100000 + i
    printf "  name: user-%04d\n", i
    printf "  email: user-%04d@example.com\n", i
    printf "  active: %s\n", (i % 7 == 0 ? "false" : "true")
    printf "  score: %d.%02d\n", (i * 37) % 100, (i * 53) % 100
    printf "  visits: %d\n", (i * i) % 10000
    if (i % 5 == 0)
      printf "  referrer: null\n"
    else
      printf "  referrer: https://example.com/campaign/%d\n", i % 23
    printf "  tags: [tier-%d, region-%s, cohort-%02d]\n", i % 4, (i % 2 == 0 ? "east" : "west"), i % 12
    printf "  address:\n"
    printf "    street: %d Elm Street\n", 100 + i % 900
    printf "    city: City-%02d\n", i % 50
    printf "    zip: \"%05d\"\n", 10000 + (i * 97) % 90000
    printf "    geo: {lat: %d.%04d, lon: -%d.%04d}\n", 30 + i % 20, (i * 31) % 10000, 70 + i % 50, (i * 41) % 10000
  }
}' > large.yaml
