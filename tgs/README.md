# TGS4 Swarm Deployment Example

*Prepared for /tg/station operations*

This sub-project can be used to deploy a swarm of [TGS4](https://github.com/tgstation/tgstation-server) servers, which will use a shared Postgres database and span across multiple hosts. This deployment does not currently make use of Docker Swarm, as the configuration requirements for each specific host seemed to not be an ideal use case for Docker Swarm.

## Necessary Host Groups

The deployment of these playbooks requires a set of hosts with the following groups...
- ``tgs_swarm_controller``: Assign to a single host, this will be the TGS swarm's controller.
- ``tgs_swarm``: Assign to every host which will run a server of the TGS swarm. *Ensure that the ``tgs_swarm_controller`` group is a member in this group*
- ``tgs_db_host``: Assign to a single host which will run the Postgres container.

## Included Playbooks

Note that the file descriptions below occur in the order they were intended to be run within a workflow.

### tgs_deploy_postgres.yaml

Deploys a Postgres container to the designated ``tgs_db_host``, which will be shared among the TGS servers within the swarm.
### tgs_configure_swarm_controller.yaml

Generates an initial configuration for the TGS swarm controller on the ``tgs_swarm_controller`` host. This allows for both the configuration of the controller to be generated, as well as exporting the internal IP of this controller to be used on the configuration of each worker TGS server.
### tgs_deploy_instances.yaml

Performs the actual deployment of TGS servers to each of the hosts, as well as generating the configuration for non-controller hosts.

## Other included files

The template for each TGS server's configuration is found in ``appsettings.Production.yml.j2``, which is used to create the configuration on each host. For more information regarding this file, see the [TGS4 documentation](https://github.com/tgstation/tgstation-server#manual-configuration).

## Deployment

These playbooks should be run sequentially in the order defined above within a workflow. The combination of these, with the following configuration variables, will result in a functional TGS swarm deployment.

### Variables to configure

**NOTE**: Please configure the following on each host within the ``tgs_swarm`` group as necessary...

```yaml
# The unique identifier used to distinguish each host in the swarm
tgs_host_identifier: 'example_identifier' # The unique identifier used to distinguish each host in the swarm
# The web panel URL used by Keycloak to redirect users logging in back to the web panel
# Ideally this should be moved to a more automated URL, but this is sufficient for now
tgs_keycloak_redirect_url: 'http://example_identifier.example.com:5000/'
# A list of the ports to publish for game servers to use, this should match the 
# ports you intend on using for each instance within this TGS server.
# Only necessary if running more than one instance per server, or if the port
# you intend to publish differs between hosts. If the port is the same for all hosts,
# this can be set in the workflow exclusively and doesn't necessitate setting this var on each host.
tgs_game_ports: [ 1337 ]
```

The following variables should be configured on the workflow itself, or within their respective playbooks. This is not an exhaustive list, but rather what is required to run the deployment properly. There may be further variables which can be configured and tweaked, found within the playbooks themselves.

```yaml
# Container versioning
tgs_container_image: 'tgstation/server:v4.8.0'
postgres_container_image: 'postgres:13.1'

# Configuration settings as required by TGS
tgs_allowed_origins: [ 'localhost', 'http://localhost:8080' ] # Allowed origins for CORS
tgs_external_port: 5000 # Port at which TGS accepts REST API requests, also where the web panel is served if enabled
github_access_token: null # GitHub PAT used for preventing API rate limiting
postgres_version: '13.1' # String used by TGS for controlling featureset use on the database driver, for postgres use Major.Minor
tgs_swarm_private_key: null # Unique private string used to cluster the TGS instances in the swarm. This is like a password, protect it.
tgs_config_version: '2.3.0' # This only surpresses warnings about config versions, currently not found anywhere public. Cyberboss intends to change that.
tgs_log_level: 'Trace' # Log level used for debugging, can be excluded if not needed.
tgs_game_ports: [ 1337 ] # A list of ports to publish on *all* TGS servers deployed, see the per-host configuration if this doesn't suit your needs.

# Keycloak configuration
# Note that the redirect URLs are configured per-host currently
# Get these values after setting up the client in Keycloak
tgs_keycloak_client_id: 'tgs'
tgs_keycloak_client_secret: 'secret_goes_here'
tgs_keycloak_server_url: 'http://auth.example.com/auth/realms/example_station'

# Postgres settings
postgres_external_port: 5433
postgres_db: 'tgs'
postgres_user: 'tgs_user'
postgres_password: 'sample_password'
```

## Things to note

Ensure to read the documentation on backing up the important data on your TGS servers, [found here](https://github.com/tgstation/tgstation-server#backuprestore). To perform backups of the TGS data, refer to the location defined in ``tgs_deploy_instances.yaml``, which should be derived from:
```yaml
# TGS directory in which the installation exists
tgs_dir: '/etc/tgs'
# Where TGS configuration files are stored
tgs_config_dir: '{{ tgs_dir }}/config'
# Where TGS instances are stored
tgs_instances_dir: '{{ tgs_dir }}/instances'
# Where TGS logs are stored
tgs_logs_dir: '{{ tgs_dir }}/logs'
```

To perform backups of the PostgreSQL database, refer to the location defined in ``tgs_deploy_postgres.yaml``, which should be:

```yaml
postgres_data_directory: /etc/postgres-storage/{{ postgres_container_name }}
```

This is the on-disk location used for the PostgreSQL database, and consequently could be used for backing up the database.