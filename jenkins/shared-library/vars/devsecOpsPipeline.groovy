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

        options {
            timeout(time: 45, unit: 'MINUTES')
            disableConcurrentBuilds()
            buildDiscarder(logRotator(numToKeepStr: '10'))
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
        }

        stages {

            stage('Load Secrets') {
                steps {
                    script {
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
                            env.CACHE_REPO      = "${env.HARBOR_REGISTRY}/${env.HARBOR_PROJECT}/cache"
                        }

                        echo "Branch: ${branch} | Image: ${env.FULL_IMAGE}"
                    }
                }
            }

            stage('Checkout') {
                steps {
                    script {
                        def scmVars = checkout scm
                        env.GIT_COMMIT = scmVars.GIT_COMMIT
                    }
                    container('manifest-updater') {
                        script {
                            sh 'git config --global --add safe.directory "*"'
                            def manualTrigger = currentBuild.getBuildCauses().any { (it._class ?: '').contains('UserIdCause') }
                            def base = env.GIT_PREVIOUS_SUCCESSFUL_COMMIT ?: ''
                            def changed = base ?
                                sh(script: "git diff --name-only ${base} ${env.GIT_COMMIT} || echo __ALL__", returnStdout: true).trim() :
                                '__ALL__'   // no baseline (first build) → don't skip
                            def relevant = (changed == '__ALL__') || changed.readLines().any { it.startsWith("${appDir}/") }
                            echo "Path filter — manual=${manualTrigger}, changes under ${appDir}=${relevant}"
                            if (!relevant && !manualTrigger) {
                                currentBuild.result = 'NOT_BUILT'
                                error("No changes under ${appDir} since last build — skipping (push trigger)")
                            }
                        }
                    }
                }
            }

            // ══════════════════════════════════════════════════════════════════
            // PR PIPELINE — lightweight feedback, no build/push
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

            stage('PR — Security Scan') {
                when { changeRequest() }
                parallel {
                    stage('SonarQube (SAST)') {
                        steps { runSonarScan(appDir, sonarKey, language) }
                    }
                    stage('Checkov (IaC)') {
                        steps { runCheckov() }
                    }
                }
            }

            // ══════════════════════════════════════════════════════════════════
            // FULL PIPELINE — runs on merge to develop or main
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
                              --tar-path /workspace/image.tar
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
                        steps { runCheckov() }
                    }

                    stage('SonarQube — SAST') {
                        steps { runSonarScan(appDir, sonarKey, language) }
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

                    stage('Trivy — K8s Manifests') {
                        steps {
                            container('trivy') {
                                sh """
                                    trivy config \
                                      --exit-code 0 \
                                      --severity HIGH,CRITICAL \
                                      k8s/helm/
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
                        sh "crane push --insecure /workspace/image.tar \${FULL_IMAGE}"
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
                            yq e '.image.tag = "${env.IMAGE_TAG}"' -i ${manifestFile}
                        """
                    }
                    container('manifest-updater') {
                        sh """
                            git add ${manifestFile}
                            git diff --cached --quiet && echo "No changes to commit" && exit 0
                            git commit -m "ci: update ${imageName} image to ${env.IMAGE_TAG} [skip ci]"
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

// ── Helpers ───────────────────────────────────────────────────────────────────

def runTests(String language) {
    switch (language) {
        case 'golang':
            sh 'go test ./... -v -coverprofile=coverage.out'
            break
        case 'java':
            sh 'chmod +x gradlew && ./gradlew test --no-daemon'
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

def runSonarScan(String appDir, String sonarKey, String language) {
    container('sonar-scanner') {
        withSonarQubeEnv('sonarqube') {
            script {
                def extraArgs = ''
                if (language == 'golang') {
                    extraArgs = "-Dsonar.go.coverage.reportPaths=coverage.out"
                } else if (language == 'java') {
                    extraArgs = "-Dsonar.java.binaries=."
                }
                sh """
                    sonar-scanner \
                      -Dsonar.projectKey=${sonarKey} \
                      -Dsonar.sources=. \
                      -Dsonar.projectBaseDir=${appDir} \
                      -Dsonar.token=\${SONAR_TOKEN} \
                      -Dsonar.host.url=\${SONAR_HOST} \
                      -Dsonar.scm.disabled=true \
                      -Dsonar.qualitygate.wait=false \
                      ${extraArgs}
                """
            }
        }
    }
}

def runCheckov() {
    container('checkov') {
        sh 'checkov -d infra/ --output cli --quiet --soft-fail'
    }
}
