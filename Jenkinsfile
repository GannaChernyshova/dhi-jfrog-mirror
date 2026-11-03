// DHI → Artifactory: the same steps as .github/workflows/mirror.yml and
// dhi-jfrog-sync.yml, for Jenkins. The scripts in scripts/ do the work.
//
// Jenkins setup (see README, "Using Jenkins"):
//   credentials  dhi-docker-oat  Secret text            the Docker organization access token (OAT)
//                dhi-jfrog       Username with password  Artifactory username + token
//   agent        Linux amd64 with bash, curl, jq and the Docker CLI
//
// Scheduled runs use the parameter defaults: MODE=sync refreshes the mirrored
// tags every hour. Run once by hand with MODE=mirror for the first copy.
pipeline {
  agent { label 'linux' }

  triggers { cron('H * * * *') }
  options {
    disableConcurrentBuilds()
    timeout(time: 1, unit: 'HOURS')
  }
  parameters {
    choice(name: 'MODE', choices: ['sync', 'mirror'],
           description: 'mirror: copy the tags below now. sync: copy only what changed on Docker Hub for those tags.')
    string(name: 'TAGS', defaultValue: '24 24-dev',
           description: 'Tags to mirror and sync, space separated.')
  }

  environment {
    // Edit these for your setup.
    DOCKER_ORG = 'your-org'            // Docker Hub organization (also the OAT's username)
    SRC_IMAGE  = 'dhi-node'            // the dhi-<name> repository on Docker Hub
    DEST_IMAGE = 'dhi-node'            // image name in Artifactory
    JFROG_HOST = 'acme.jfrog.io'       // no https://
    JFROG_REPO = 'your-repo'           // the Artifactory Docker repository

    TAGS = "${params.TAGS}"
    REGCLIENT_VERSION = 'v0.11.7'
    COSIGN_VERSION    = 'v3.1.4'
  }

  stages {
    stage('Install tools') {
      steps {
        sh '''
          mkdir -p "$WORKSPACE/bin"
          for b in regctl regsync; do
            [ -x "$WORKSPACE/bin/$b" ] || curl -sSfL \
              "https://github.com/regclient/regclient/releases/download/${REGCLIENT_VERSION}/$b-linux-amd64" \
              -o "$WORKSPACE/bin/$b"
          done
          [ -x "$WORKSPACE/bin/cosign" ] || curl -sSfL \
            "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64" \
            -o "$WORKSPACE/bin/cosign"
          chmod +x "$WORKSPACE"/bin/*
        '''
      }
    }

    stage('Mirror and verify') {
      steps {
        withCredentials([
          string(credentialsId: 'dhi-docker-oat', variable: 'DOCKER_TOKEN'),
          usernamePassword(credentialsId: 'dhi-jfrog',
                           usernameVariable: 'JFROG_USER', passwordVariable: 'JFROG_TOKEN')
        ]) {
          sh '''
            export PATH="$WORKSPACE/bin:$PATH"
            bash scripts/01-login.sh
            if [ "$MODE" = mirror ]; then
              bash scripts/02-inspect.sh
              bash scripts/03-mirror.sh
            else
              bash scripts/05-sync.sh
              bash scripts/02-inspect.sh >/dev/null   # refreshes and checks the DHI key
            fi
            bash scripts/04-verify.sh
          '''
        }
      }
    }
  }
}
