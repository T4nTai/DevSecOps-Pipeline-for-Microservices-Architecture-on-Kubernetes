def builderImage(String language) {
    def images = [
        golang: 'golang:1.26-alpine',
        java:   'gradle:8-jdk21-alpine',
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
      image: sonarsource/sonar-scanner-cli:latest
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      resources:
        requests:
          cpu: "50m"
          memory: "256Mi"
        limits:
          cpu: "300m"
          memory: "512Mi"

    - name: checkov
      image: bridgecrew/checkov:latest
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
