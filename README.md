# Keycloak Clustered Deployment Example

*Prepared for /tg/station operations*

## Included Playbooks

Note that the file descriptions below occur in the order they were intended to be run within a workflow.

### docker_swarm_create.yaml

Ensures a docker swarm is created for the Keycloak deployment, this playbook will ensure the presence of a swarm and export the secrets to variables to be used in a workflow. This playbook is intended to be run on a single manager node.

### docker_swarm_join.yaml

Joins worker nodes to the swarm, this relies on the variables set from the ``docker_swarm_create.yaml`` playbook. This should be run on non-manager nodes.

### docker_swarm_network.yaml

Ensures an overlay network is created for the docker swarm to support traefik's load balancing to the Keycloak instances. This should be run on a single manager node.

### keycloak_clustered_deployment.yaml

Deploys a Keycloak service to every worker node, and deploys a PostgreSQL database to the manager node. The database backs the Keycloak instances for their persistent data, as well as facilitating the clustering behaviour through JDBC. Note the stack configuration puts the Keycloak services under the traefik network to expose them to a traefik container for load balancing.

### traefik_deployment.yaml

Deploys a traefik container to the manager node of the swarm. Note the stack configuration puts the service under the traefik network to allow for load-balancing access to the Keycloak containers.

## Deployment

These playbooks should be run sequentially in the order defined above within a workflow. The combination of these, with the following configuration variables, will result in a functional Keycloak deployment.

### Variables to configure

The following variables should be configured on the workflow itself, or within their respective playbooks.

```yaml
# Docker network settings
docker_network_driver: 'overlay'
docker_network_name: 'traefik'

# Container images for the deployment
postgres_container_image: postgres:13.1
keycloak_container_image: ivanfranchin/keycloak-clustered:12.0.1

# Keycloak container name, used for naming of containers on individual hosts
keycloak_container_name: keycloak_12_0_1

# Keycloak configuration settings
keycloak_frontend_url: http://localhost/auth
default_keycloak_user: admin # The username used for the default user
default_keycloak_password: null # The password used for the default user
postgres_address: null # The address at which the postgres service can be reached
postgres_db: keycloak # The postgres service's default db name
postgres_user: keycloak # The postgres service's default db user
postgres_password: null # The postgres service's default user's password

# Traefik configuration, used for routing to the traefik panel as well as the keycloak load balancer
traefik_external_rule: 'Host(`localhost`)'
keycloak_traefik_rule: 'Host(`localhost`) && PathPrefix(`/auth`)'
```

## Things to note

The playbooks are not currently configured for using HTTPS, as the example traefik setup MSO gave me was, and should be modified to include this prior to final deployment.