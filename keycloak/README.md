# Keycloak Clustered Deployment Example

*Prepared for /tg/station operations*

This project can be used to deploy a distributed Keycloak installation, which will have multiple Keycloak servers spread across different hosts backed with a PostgreSQL database.

## Necessary Host Groups

The deployment of these playbooks requires a set of hosts with the following groups...

``docker_swarm_manager``: Assign to a single host, this will be the manager of the swarm

``docker_swarm_worker``: Assign to each non-manager host which will host a Keycloak instance, these will be workers added to the docker swarm.

## Included Playbooks

Note that the file descriptions below occur in the order they were intended to be run within a workflow.

### docker_swarm_create.yaml

Ensures a docker swarm is created for the Keycloak deployment, this playbook will ensure the presence of a swarm and export the secrets to variables to be used in a workflow. This playbook is intended to be run on a single manager node.

### docker_swarm_join.yaml

Joins worker nodes to the swarm, this relies on the variables set from the ``docker_swarm_create.yaml`` playbook. This should be run on non-manager nodes.

### docker_swarm_network.yaml

Ensures an overlay network is created for the docker swarm to support Traefik's load balancing to the Keycloak instances. This should be run on a single manager node.

### keycloak_clustered_deployment.yaml

Deploys a Keycloak service to every worker node, and deploys a PostgreSQL database to the manager node. The database backs the Keycloak instances for their persistent data, as well as facilitating the clustering behaviour through JDBC. Note the stack configuration puts the Keycloak services under the Traefik network to expose them to a Traefik service for load balancing.

### traefik_deployment.yaml

Deploys a Traefik service to the manager node of the swarm. Note the stack configuration puts the service under the Traefik network to allow for load-balancing access to the Keycloak service.

## Deployment

These playbooks should be run sequentially in the order defined above within a workflow. The combination of these, with the following configuration variables, will result in a functional Keycloak deployment.

### Variables to configure

The following variables should be configured on the workflow itself, or within their respective playbooks. This is not an exhaustive list, but rather what is required to run the deployment properly. There are further variables which can be configured and tweaked, found within the playbooks themselves.

```yaml
# Docker network settings
docker_network_driver: 'overlay'
docker_network_name: 'traefik'

# Container images for the deployment
postgres_container_image: postgres:13.1
keycloak_container_image: ivanfranchin/keycloak-clustered:12.0.1

# Keycloak container name, used for naming of containers on individual hosts,
# as well as dictating the folder name for the PostgreSQL data directory
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

The playbooks are not currently configured for using HTTPS, as the example Traefik setup MSO gave me was, and should be modified to include this prior to final deployment.

To perform backups of the PostgreSQL database, refer to the location defined in ``keycloak_clustered_deployment.yaml``, which should be:

```yaml
postgres_data_directory: /etc/postgres-storage/{{ keycloak_container_name }}
```

This is the on-disk location used for the PostgreSQL database, and consequently could be used for backing up the database.