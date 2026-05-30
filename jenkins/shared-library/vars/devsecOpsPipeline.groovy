def call(Map config) {
    def appDir       = config.appDir
    def imageName    = config.imageName
    def language     = config.language  ?: 'golang'
    def sonarKey     = config.sonarKey  ?: imageName
    def manifestFile = config.manifestFile ?: "k8s/helm/values/${imageName}.yaml"
    def podYaml      = podTemplates.getTemplate(language)

    pipeline {
        agent {
            kubernetes {
                defaultContainer 'builder'
                yaml podYaml
            }
        }

        triggers {
            githubPush()
        }

        environment {
            IMAGE_NAME     = "${imageName}"
            APP_DIR        = "${appDir}"
            HARBOR_PROJECT = 'library'
            VAULT_ADDR     = 'http://vault.vault.svc.cluster.local:8200'
            SONAR_HOST     = 'http://sonarqube.sonarqube.svc.cluster.local:9000'
            // IMAGE_TAG and FULL_IMAGE are set dynamically in 'Load Secrets'
            // based on branch: develop → dev-N, main → N
        }

        stages {

            // ── Always: load secrets + set branch-aware image tag ─────────────
            stage('Load Secrets') {
                steps {
                    script {
                        // Branch-aware tag: develop → dev-42, main → 42
                        def branch = env.BRANCH_NAME ?: 'develop'
                        env.IMAGE_TAG       = (branch == 'main') ? "${BUILD_NUMBER}" : "dev-${BUILD_NUMBER}"
                        env.MANIFEST_BRANCH = branch

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

                        echo "Branch: ${branch} | Image: ${env.FULL_IMAGE}"
                    }
                }
            }

            stage('Checkout') {
                steps {
                    checkout scm
                    script {
                        def msg = sh(script: 'git log -1 --format=%B', returnStdout: true).trim()
                        if (msg.contains('[skip ci]')) {
                            currentBuild.result = 'NOT_BUILT'
                            error('[skip ci] detected — skipping build')
                        }
                    }
                }
            }

            // ══════════════════════════════════════════════════════════════════
            // PR PIPELINE — lightweight feedback, no build/push
            // Triggered when opening/updating a PR toward develop or main
            // ══════════════════════════════════════════════════════════════════

            stage('PR — Unit Tests') {
                when { changeRequest() }
                steps {
                    container('builder') {
                        dir(appDir) {
                            script { runTests(language) }
                        }
                    }
                }
            }

            stage('PR — SonarQube (SAST)') {
                when { changeRequest() }
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

            stage('PR — Checkov (IaC)') {
                when { changeRequest() }
                steps {
                    container('checkov') {
                        sh 'checkov -d infra/ --output cli --soft-fail --quiet'
                    }
                }
            }

            // ══════════════════════════════════════════════════════════════════
            // FULL PIPELINE — runs on merge to develop or main
            // develop: build dev image, push dev tag, update manifest → develop
            // main:    build prod image, push prod tag, update manifest → main
            // ══════════════════════════════════════════════════════════════════

            stage('Build Image') {
                when { anyOf { branch 'develop'; branch 'main' } }
                steps {
                    container('kaniko') {
                        sh """
                            /kaniko/executor \
                              --context="\${WORKSPACE}/${appDir}" \
                              --dockerfile="\${WORKSPACE}/${appDir}/Dockerfile" \
                              --no-push \
                              --tar-path /workspace/image.tar \
                              --insecure \
                              --skip-tls-verify \
                              --cache=false
                        """
                    }
                }
            }

            stage('Unit Tests') {
                when { anyOf { branch 'develop'; branch 'main' } }
                steps {
                    container('builder') {
                        dir(appDir) {
                            script { runTests(language) }
                        }
                    }
                }
            }

            stage('Security Scan') {
                when { anyOf { branch 'develop'; branch 'main' } }
                parallel {

                    stage('Checkov — IaC') {
                        steps {
                            container('checkov') {
                                sh 'checkov -d infra/ --output cli --soft-fail --quiet'
                            }
                        }
                    }

                    stage('SonarQube — SAST') {
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

                    stage('Trivy — Image Scan') {
                        steps {
                            container('trivy') {
                                sh """
                                    trivy image \
                                      --exit-code 0 \
                                      --severity HIGH,CRITICAL \
                                      --no-progress \
                                      --input /workspace/image.tar
                                """
                            }
                        }
                    }

                }
            }

            stage('Push Image') {
                when { anyOf { branch 'develop'; branch 'main' } }
                steps {
                    container('crane') {
                        sh """
                            crane push /workspace/image.tar \${FULL_IMAGE} \
                              --insecure
                        """
                    }
                }
            }

            stage('Update Manifest') {
                when { anyOf { branch 'develop'; branch 'main' } }
                steps {
                    container('manifest-updater') {
                        sh """
                            git config --global --add safe.directory "\${WORKSPACE}"
                            git config user.email "jenkins@ci.local"
                            git config user.name "Jenkins"
                            git fetch origin \${MANIFEST_BRANCH}
                            git checkout \${MANIFEST_BRANCH}
                        """
                    }
                    container('yq') {
                        sh """
                            echo "Updating ${manifestFile} → image.tag = \${IMAGE_TAG}"
                            yq e '.image.tag = "\${IMAGE_TAG}"' -i ${manifestFile}
                        """
                    }
                    container('manifest-updater') {
                        sh """
                            git add ${manifestFile}
                            git diff --cached --quiet && echo "No changes to commit" && exit 0
                            git commit -m "ci: update ${imageName} image to \${IMAGE_TAG} [skip ci]"
                            git push https://\${GIT_USER}:\${GIT_TOKEN}@\$(git remote get-url origin | sed 's|https://||') HEAD:\${MANIFEST_BRANCH}
                        """
                    }
                }
            }

        }

        post {
            success {
                script {
                    if (env.CHANGE_ID) {
                        echo "PR checks passed — ${imageName} ready for review"
                    } else {
                        echo "Pipeline passed — ${imageName}:${env.IMAGE_TAG} deployed to ${env.MANIFEST_BRANCH}"
                    }
                }
            }
            failure {
                echo "Pipeline failed — ${imageName} build #${env.BUILD_NUMBER} on ${env.BRANCH_NAME}"
            }
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
