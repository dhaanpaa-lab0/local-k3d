allow_k8s_contexts('lk3d-cluster')

# Apply Kubernetes manifests
#   Tilt will build & push any necessary images, re-deploying your
#   resources as they change.
#
#   More info: https://docs.tilt.dev/api.html#api.k8s_yaml
#
# k8s_yaml(['k8s/deployment.yaml', 'k8s/service.yaml'])

k8s_yaml('manifests/shell.deployment.yaml')
k8s_yaml('manifests/example-init.deployment.yaml')

# Customize a Kubernetes resource
#   By default, Kubernetes resource names are automatically assigned
#   based on objects in the YAML manifests, e.g. Deployment name.
#
#   Tilt strives for sane defaults, so calling k8s_resource is
#   optional, and you only need to pass the arguments you want to
#   override.
#
#   More info: https://docs.tilt.dev/api.html#api.k8s_resource
#
# k8s_resource('my-deployment',
#              # map one or more local ports to ports on your Pod
#              port_forwards=['5000:8080'],
#              # change whether the resource is started by default
#              auto_init=False,
#              # control whether the resource automatically updates
#              trigger_mode=TRIGGER_MODE_MANUAL
# )


# Run local commands
#   Local commands can be helpful for one-time tasks like installing
#   project prerequisites. They can also manage long-lived processes
#   for non-containerized services or dependencies.
#
#   More info: https://docs.tilt.dev/local_resource.html
#
local_resource('install-brewfile', cmd='brew bundle install', auto_init=False, trigger_mode=TRIGGER_MODE_MANUAL)


# Extensions are open-source, pre-packaged functions that extend Tilt
#
#   More info: https://github.com/tilt-dev/tilt-extensions
#
load('ext://git_resource', 'git_checkout')
load('ext://helm_remote', 'helm_remote')

# Argo Workflows
#   Install Argo Workflows using Helm
#   Trigger manually from Tilt UI to install
helm_remote(
    'argo-workflows',
    repo_name='argo',
    repo_url='https://argoproj.github.io/argo-helm',
    namespace='argo',
    create_namespace=True,
    set=['server.extraArgs={--auth-mode=server}']
)

k8s_resource(
    'argo-workflows-server',
    port_forwards=['2746:2746'],
    auto_init=False,
    trigger_mode=TRIGGER_MODE_MANUAL
)
