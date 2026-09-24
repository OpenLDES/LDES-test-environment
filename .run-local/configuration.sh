# Create token: https://api.ovh.com/createToken/?GET=/*&POST=/*&PUT=/*&DELETE=/*
export OVH_ENDPOINT='ovh-eu'
export OVH_APPLICATION_KEY='***'
export OVH_APPLICATION_SECRET='***'
export OVH_CONSUMER_KEY='***'

# Terraform remote state on OVHcloud Object Storage (S3 compatible).
export AWS_ACCESS_KEY_ID='***'
export AWS_SECRET_ACCESS_KEY='***'
export TF_STATE_BUCKET='ldes-test-environment-tfstate'
export TF_STATE_ENDPOINT='https://s3.gra.io.cloud.ovh.net'
export TF_STATE_REGION='gra'

# Name of the LDES environment. Becomes the state key, the namespace (ldes-<name>) and the
# hostname, so it must be a DNS label of at most 32 characters.
export ENVIRONMENT_NAME='platform'

# Images under test.
export LDES_SERVER_IMAGE_TAG='4.1.2'
export LDIO_IMAGE_TAG='3.1.1'

# Load test. These are the names k6 actually reads (loadtest/lib/config.js); the LOADTEST_* names
# are GitHub repository variables that only exist inside the workflow.
export INGEST_VUS='20'
export QUERY_VUS='10'
export QUERY_RATE='10'
export QUERY_DURATION_SECONDS='180'
export SETTLE_SECONDS='45'
export MEMBER_SCALE='20'          # 0.1 for a quick smoke run, 20 for a long run

