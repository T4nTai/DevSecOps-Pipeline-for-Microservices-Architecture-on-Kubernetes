def call(Map config) {
    def appDir       = config.appDir
    def imageName    = config.imageName
    def language     = config.language     ?: 'golang'
    def sonarKey     = config.sonarKey     ?: imageName
    def podYaml = podTemplates.getTemplate(language)
    def manifestFile = config.manifestFile ?: "k8s/apps/${imageName}/rollout.yaml"

    pipeline {
        agent {
            kubernetes {
                defaultContainer 'builder'
                yaml podYaml
            }
        }

        environment {
            IMAGE_NAME     = "${imageName}"
            IMAGE_TAG      = "${BUILD_NUMBER}"
            APP_DIR        = "${appDir}"
            HARBOR_PROJECT = 'library'
            VAULT_ADDR     = 'http://vault.vault.svc.cluster.local:8200'
            SONAR_HOST     = 'http://sonarqube.sonarqube.svc.cluster.local:9000'
        }

        stages {

            stage('Load Secrets') {
                steps {
                    script {
                        withVault(
                            configuration: [
                                vaultUrl:          env.VAULT_ADDR,
                                vaultCredentialId: 'vault-approle',
                                engineVersion:     2
                            ],
                            vaultSecrets: [
                                [path: 'secret/git', secretValues: [
                                    [envVar: 'GIT_USER',  vaultKey: 'username'],
                                    [envVar: 'GIT_TOKEN', vaultKey: 'token']
                                ]],
                                [path: 'secret/harbor', secretValues: [
                                    [envVar: 'HARBOR_REGISTRY', vaultKey: 'registry']
                                ]],
                                [path: 'secret/sonarqube', secretValues: [
                                    [envVar: 'SONAR_TOKEN', vaultKey: 'token']
                                ]]
                            ]
                        ) {
                            env.GIT_USER        = env.GIT_USER
                            env.GIT_TOKEN       = env.GIT_TOKEN
                            env.HARBOR_REGISTRY = env.HARBOR_REGISTRY
                            env.SONAR_TOKEN     = env.SONAR_TOKEN
                            env.FULL_IMAGE      = "${env.HARBOR_REGISTRY}/${env.HARBOR_PROJECT}/${imageName}:${env.IMAGE_TAG}"
                        }

                    }
                }
            }

            stage('Checkout') {
                steps { checkout scm }
            }

            stage('Test & IaC Scan') {
                parallel {
                    stage('Unit Tests') {
                        steps {
                            container('builder') {
                                dir(appDir) {
                                    script { runTests(language) }
                                }
                            }
                        }
                    }
                    stage('Checkov — IaC Scan') {
                        steps {
                            container('checkov') {
                                sh 'checkov -d terraform/ --output cli --soft-fail --quiet'
                            }
                        }
                    }
                }
            }

            stage('SonarQube Analysis') {
                steps {
                    container('sonar-scanner') {
                        withSonarQubeEnv('sonarqube') {
                            script {
                                def extraArgs = (language == 'golang')
                                    ? "-Dsonar.go.coverage.reportPaths=${appDir}/coverage.out"
                                    : ''
                                sh """
                                    sonar-scanner \
                                      -Dsonar.projectKey=${sonarKey} \
                                      -Dsonar.sources=${appDir} \
                                      -Dsonar.token=\${SONAR_TOKEN} \
                                      -Dsonar.host.url=\${SONAR_HOST} \
                                      -Dsonar.scm.disabled=true \
                                      ${extraArgs}
                                """
                            }
                        }
                        timeout(time: 15, unit: 'MINUTES') {
                            waitForQualityGate abortPipeline: true
                        }
                    }
                }
            }

            stage('Build & Push Image') {
                steps {
                    container('kaniko') {
                        sh """
                            /kaniko/executor \
                              --context="\${WORKSPACE}/${appDir}" \
                              --dockerfile="\${WORKSPACE}/${appDir}/Dockerfile" \
                              --destination="\${FULL_IMAGE}" \
                              --insecure \
                              --skip-tls-verify \
                              --cache=true
                        """
                    }
                }
            }

            stage('Trivy — Image Scan') {
                steps {
                    container('trivy') {
                        sh """
                            trivy image \
                              --exit-code 0 \
                              --severity HIGH,CRITICAL \
                              --no-progress \
                              --insecure \
                              \${FULL_IMAGE}
                        """
                    }
                }
            }

            stage('Update Manifest') {
                steps {
                    container('yq') {
                        sh """
                            yq e '.spec.template.spec.containers[0].image = "\${FULL_IMAGE}"' \
                              -i ${manifestFile}
                        """
                    }
                    container('manifest-updater') {
                        sh """
                            git config --global --add safe.directory "\${WORKSPACE}"
                            git config user.email "jenkins@ci.local"
                            git config user.name "Jenkins"
                            git add ${manifestFile}
                            git commit -m "ci: update ${imageName} image to \${IMAGE_TAG}"
                            git push https://\${GIT_USER}:\${GIT_TOKEN}@\$(git remote get-url origin | sed 's|https://||') HEAD:main
                        """
                    }
                }
            }
        }

        post {
            success { echo "Pipeline passed — ${imageName}:${env.IMAGE_TAG}" }
            failure { echo "Pipeline failed — ${imageName} build #${env.BUILD_NUMBER}" }
        }
    }
}

def runTests(String language) {
    switch (language) {
        case 'golang':
            sh 'go test ./... -v -coverprofile=coverage.out'
            break
        case 'java':
            sh './gradlew test --no-daemon'
            break
        case 'nodejs':
            sh 'npm ci && npm test'
            break
        case 'python':
            sh 'pip install -r requirements.txt -q && pytest --tb=short'
            break
        case 'dotnet':
            sh 'dotnet test --no-build --verbosity normal'
            break
        default:
            echo "No test command defined for language: ${language}"
    }
}
