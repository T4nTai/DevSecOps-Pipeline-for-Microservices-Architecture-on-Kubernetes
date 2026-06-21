def builderImage(String language) {
    def images = [
        golang: 'golang:1.26-alpine',
        java:   'gradle:8-jdk21',
        nodejs: 'node:20-alpine',
        python: 'python:3.12-slim',
        dotnet: 'mcr.microsoft.com/dotnet/sdk:8.0'
    ]
    return images.get(language, 'alpine:3.19')
}

def builderEnv(String language) {
    if (language == 'golang') {
        return '''
      env:
        - name: GOPATH
          value: /go
        - name: CGO_ENABLED
          value: "0"'''
    }
    return ''
}

def getTemplate(String language) {
    return """
apiVersion: v1
kind: Pod
spec:
  serviceAccountName: jenkins
  hostAliases:
    - ip: "10.99.226.55"
      hostnames:
        - "harbor.tools.votantai.me"
  containers:
    - name: builder
      image: ${builderImage(language)}
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      resources:
        requests:
          cpu: "50m"
          memory: "256Mi"
        limits:
          cpu: "500m"
          memory: "1Gi"${builderEnv(language)}

    - name: sonar-scanner
      image: sonarsource/sonar-scanner-cli:5.0.1
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      env:
        - name: SONAR_SCANNER_OPTS
          value: "-Xmx1g"
      resources:
        requests:
          cpu: "50m"
          memory: "512Mi"
        limits:
          cpu: "500m"
          memory: "2Gi"

    - name: checkov
      image: bridgecrew/checkov:3.2.0
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      resources:
        requests:
          cpu: "50m"
          memory: "512Mi"
        limits:
          cpu: "300m"
          memory: "1Gi"

    - name: kaniko
      image: gcr.io/kaniko-project/executor:debug
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      resources:
        requests:
          cpu: "100m"
          memory: "512Mi"
        limits:
          cpu: "1000m"
          memory: "2Gi"
      volumeMounts:
        - name: kaniko-secret
          mountPath: /kaniko/.docker
        - name: image-workspace
          mountPath: /workspace

    - name: trivy
      image: aquasec/trivy:0.61.0
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      resources:
        requests:
          cpu: "50m"
          memory: "256Mi"
        limits:
          cpu: "500m"
          memory: "1Gi"
      volumeMounts:
        - name: kaniko-secret
          mountPath: /root/.docker
        - name: image-workspace
          mountPath: /workspace

    - name: crane
      image: gcr.io/go-containerregistry/crane:debug
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      resources:
        requests:
          cpu: "50m"
          memory: "64Mi"
        limits:
          cpu: "200m"
          memory: "256Mi"
      volumeMounts:
        - name: kaniko-secret
          mountPath: /root/.docker
        - name: image-workspace
          mountPath: /workspace

    - name: yq
      image: mikefarah/yq:4.44.3
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      resources:
        requests:
          cpu: "25m"
          memory: "64Mi"
        limits:
          cpu: "100m"
          memory: "128Mi"

    - name: manifest-updater
      image: alpine/git:2.47.2
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      resources:
        requests:
          cpu: "25m"
          memory: "64Mi"
        limits:
          cpu: "100m"
          memory: "128Mi"

  volumes:
    - name: kaniko-secret
      secret:
        secretName: harbor-credentials
        items:
          - key: .dockerconfigjson
            path: config.json
    - name: image-workspace
      emptyDir: {}
"""
}
