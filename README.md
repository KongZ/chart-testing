# Chart Testing

This repository provide a script for testing Helm Chart. What is this script doing

- `Jenkinsfile` will checkout 2 branches. The PR branch and Target branch.
- The script will compare PR branch with TARGET_BRANCH. If any changing in chart folder, it will run tests on them
- Pull and run `quay.io/helmpack/chart-testing` image. This image contains pre-installed chart testing tool, kubectl and helm
- Start Kind (Kubernetes in Docker)
- Configure and provisioning Kind
- Run `helm lint` on changing charts
- Run `helm install` on changing charts
- Monitor the install status and pods status. If all pods are running, then run `helm del`

Note 1: If charts have dependencies, you have to put `requirements.yaml` file in the the chart folder. The tool will automatically download and install all dependencies.

Note 2: If charts have dependencies and you won't to test, you can put chart names in `chart-testing.ignore` file. The script will ignore chart testing if they are in the list.

## To setup Github on Jenkins
 - https://wiki.jenkins.io/display/JENKINS/GitHub+Plugin

References:
 - https://github.com/kubernetes-sigs/kind
 - https://github.com/helm/chart-testing
