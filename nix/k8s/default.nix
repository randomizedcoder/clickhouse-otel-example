# K8s Manifest Generator
#
# Generates Kubernetes manifests with configuration from ports.nix
# This ensures URLs, ports, and other settings are consistent across the stack.
{ lib, pkgs, k8sStaticPath }:

let
  ports = import ../ports.nix;

  # Generate HyperDX deployment with correct URLs
  hyperdxDeployment = pkgs.writeText "hyperdx-deployment.yaml" ''
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: hyperdx
      namespace: otel-demo
      labels:
        app: hyperdx
        app.kubernetes.io/name: hyperdx
        app.kubernetes.io/component: visualization
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: hyperdx
      template:
        metadata:
          labels:
            app: hyperdx
        spec:
          containers:
            - name: hyperdx
              image: hyperdx/hyperdx:latest
              imagePullPolicy: IfNotPresent
              env:
                # MongoDB backend for session storage
                - name: MONGO_URI
                  value: "mongodb://mongodb.otel-demo.svc.cluster.local:27017/hyperdx"
                # ClickHouse connection
                - name: CLICKHOUSE_HOST
                  value: "clickhouse.otel-demo.svc.cluster.local"
                - name: CLICKHOUSE_PORT
                  value: "${toString ports.services.clickhouseHttp}"
                - name: CLICKHOUSE_USER
                  value: "default"
                - name: CLICKHOUSE_PASSWORD
                  value: ""
                # Disable authentication for demo
                - name: HYPERDX_AUTH_DISABLED
                  value: "true"
                # Frontend URL for redirects (uses externalHost from ports.nix)
                - name: FRONTEND_URL
                  value: "http://${ports.externalHost}:${toString ports.nodePorts.hyperdxApp}"
                # API URL for frontend
                - name: NEXT_PUBLIC_API_URL
                  value: "http://${ports.externalHost}:${toString ports.nodePorts.hyperdxApi}"
                # Auto-provision ClickHouse connection
                - name: DEFAULT_CONNECTIONS
                  value: '[{"name":"Default","host":"http://clickhouse.otel-demo.svc.cluster.local:${toString ports.services.clickhouseHttp}","username":"default","password":""}]'
                # Auto-provision OTel logs source
                - name: DEFAULT_SOURCES
                  value: '[{"name":"OTel Logs","kind":"log","connection":"Default","from":{"databaseName":"default","tableName":"otel_logs"},"timestampValueExpression":"Timestamp","bodyExpression":"Body","severityTextExpression":"SeverityText","serviceNameExpression":"ServiceName","traceIdExpression":"TraceId","spanIdExpression":"SpanId"}]'
                # Server ports
                - name: PORT
                  value: "${toString ports.services.hyperdxApi}"
                - name: FRONTEND_PORT
                  value: "${toString ports.services.hyperdxApp}"
              ports:
                - name: api
                  containerPort: ${toString ports.services.hyperdxApi}
                  protocol: TCP
                - name: ui
                  containerPort: ${toString ports.services.hyperdxApp}
                  protocol: TCP
              livenessProbe:
                httpGet:
                  path: /health
                  port: api
                initialDelaySeconds: 60
                periodSeconds: 30
                timeoutSeconds: 10
                failureThreshold: 3
              readinessProbe:
                httpGet:
                  path: /health
                  port: api
                initialDelaySeconds: 30
                periodSeconds: 10
                timeoutSeconds: 5
                failureThreshold: 3
              resources:
                requests:
                  memory: "512Mi"
                  cpu: "250m"
                limits:
                  memory: "1Gi"
                  cpu: "1000m"
    ---
    apiVersion: v1
    kind: Service
    metadata:
      name: hyperdx
      namespace: otel-demo
      labels:
        app: hyperdx
    spec:
      type: NodePort
      ports:
        - name: api
          port: ${toString ports.services.hyperdxApi}
          targetPort: ${toString ports.services.hyperdxApi}
          nodePort: ${toString ports.nodePorts.hyperdxApi}
          protocol: TCP
        - name: ui
          port: ${toString ports.services.hyperdxApp}
          targetPort: ${toString ports.services.hyperdxApp}
          nodePort: ${toString ports.nodePorts.hyperdxApp}
          protocol: TCP
      selector:
        app: hyperdx
  '';

in pkgs.runCommand "k8s-manifests" { } ''
  mkdir -p $out/hyperdx

  # Copy static manifests (excluding hyperdx deployment which we generate)
  cp -r ${k8sStaticPath}/* $out/

  # Replace hyperdx deployment with generated one
  rm -f $out/hyperdx/deployment.yaml
  cp ${hyperdxDeployment} $out/hyperdx/deployment.yaml
''
