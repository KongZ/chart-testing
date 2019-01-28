#!/usr/bin/env groovy

node () {
  stage ('Checking out') {
    echo "Source branch: ${scm.branches[0].name}"
    echo "Target branch: ${env.CHANGE_TARGET}"
    // If you configure Jenkins's Github plugin to `Discover pull requests from origin`, the CHARGE_TARGET will automatically fill with value.
    // Otherwise, CHANGE_TARGET will be null.
    if (env.CHANGE_TARGET == null) {
      env.CHANGE_TARGET = 'develop'
      checkout([
        $class: 'GitSCM',
        branches: [[name: env.CHANGE_TARGET]],
        doGenerateSubmoduleConfigurations: scm.doGenerateSubmoduleConfigurations,
        userRemoteConfigs: scm.userRemoteConfigs
      ])
    }
    checkout scm
  }

  try {
    if (env.CHANGE_TARGET != null) {
      stage ('Testing') {
        ansiColor('xterm') {
          withCredentials([file(credentialsId: '9b3d16e3-e9a9-4f33-96a8-47c22b3dc69a', variable: 'GCSKEY')]) {
            env.TARGET_BRANCH = "remotes/origin/${env.CHANGE_TARGET}"
            env.GCLOUD_KEY = "${GCSKEY}"
            sh "gcloud auth activate-service-account --key-file=${GCSKEY}"
            sh "gcloud auth configure-docker"
            sh "./chart-testing.sh"
          }
        }
      }
    }
  } catch (e) {
    currentBuild.result = 'FAILED'
    throw e
  } finally {
    // Send notification to Slack channel
    notifyBuild(currentBuild.result)
  }
}

def notifyBuild(String buildStatus) {
  buildStatus = buildStatus ?: 'SUCCESSFUL'
  colorCode = ""
  prefix = ""
  message = "<${env.BUILD_URL}|#${env.BUILD_NUMBER} ${env.JOB_NAME}>"

  if (buildStatus == 'SUCCESSFUL') {
    colorCode = '#00FF00'
    prefix = ":white_check_mark:"
  } else if (buildStatus == 'UNSTABLE')  {
    colorCode = '#E6E609'
    prefix = ":mostly_sunny:"
  } else {
    colorCode = '#FF0000'
    prefix = ":boom:"
  }

  slackSend(color: colorCode, message: "${prefix} ${message}", channel: "#devops")
}
