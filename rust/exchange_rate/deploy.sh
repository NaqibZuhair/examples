#!/bin/bash

# Call the script with deploy.sh {testnet} {git_revision}
if [[ $# -lt 2 ]]; then
    echo "Number of arguments supplied not correct. Call this script: \
    ./deploy.sh {testnet} {git_revision}"
    exit 1
fi

TESTNET=$1
GIT_REVISION=$2

# Create workspace for testnet and canister deployment
WORKSPACE="$(pwd)/deployment_logs"
if [ -d "$WORKSPACE" ]; then
    rm -rf $WORKSPACE
fi
mkdir $WORKSPACE

# Get a random string as identity name
IDENTITY=$(echo $RANDOM | md5sum | head -c 20)

# Create a new identity without passphrase
dfx identity new $IDENTITY --disable-encryption
echo $IDENTITY > $WORKSPACE/identity.log
echo "Created new identity $IDENTITY"

# Deploys testnet
echo "Cloning IC and deploy testnet"
git clone git@gitlab.com:dfinity-lab/public/ic.git
TESTNET_LOG="$WORKSPACE/testnet_deployment.log"
./ic/testnet/tools/icos_deploy.sh $TESTNET --git-revision "$GIT_REVISION" --no-boundary-nodes &> "$TESTNET_LOG"
echo "Testnet $TESTNET deployed."

# Obtains nns_node URL
NNS_URL=$(grep "$TESTNET-0-" "$TESTNET_LOG" | tail -1 | grep -o -P '(?<=http).*(?=8080)' | sed 's/$/8080/' | sed 's/^/http/')
echo $NNS_URL > $WORKSPACE/nns_url.log
echo "Obtained NNS subnet URL: $NNS_URL"

# Obtains app_node URL
APP_URL=$(grep "$TESTNET-1-" "$TESTNET_LOG" | tail -1 | grep -o -P '(?<=http).*(?=8080)' | sed 's/$/8080/' | sed 's/^/http/')
echo "Obtained application subnet URL: $APP_URL"

# Enables the http_request feature on application subnet 1
cd ic/rs
nix-shell --run "NNS_URL=$(cat ../../deployment_logs/nns_url.log); cargo run --bin ic-admin -- --nns-url=$NNS_URL propose-to-update-subnet --features http_requests --subnet 1 --test-neuron-proposer;"
cd ../../
rm -rf ic

# Updates dfx.json to app_node URL
jq ".networks.$TESTNET = { \
    \"type\": \"persistent\",\
    \"providers\": [\
        \"$APP_URL\"\
    ]\
}" dfx.json > dfx.json.new
mv dfx.json.new dfx.json
echo "Estabilished $TESTNET address in dfx.json file."

# Clean up canister_ids.json
rm -f canister_ids.json

# Generate declarations with loca DFX
rm -rf .dfx
dfx start --background
dfx deploy--with-cycles=200000000000 
dfx stop

# remove prebuild script in package.json before deploying to remote testnet
jq 'del(.scripts.prebuild)' package.json > package.json.new
mv package.json.new package.json

# Deploys exchange_rate to app_node
CANISTER_LOG="$WORKSPACE/canister_deployment.log"
dfx identity use $IDENTITY
dfx deploy --network $TESTNET --with-cycles=200000000000 &> "$CANISTER_LOG"
echo "Deployed canisters to $TESTNET"

# Obtains canisters URLs
for map in $(jq -c '. | to_entries | .[]' canister_ids.json); do
    canister_name=$(echo $map | jq -r '.key')
    canister_id=$(echo $map| jq -r ".value.$TESTNET")
    echo "$canister_name URL: https://$canister_id.$TESTNET.dfinity.network"
done

# A brief test on the backend
dfx canister --network $TESTNET call exchange_rate get_rates '(record {start=1658351172; end=1658358172;})'
sleep 20
dfx canister --network $TESTNET call exchange_rate get_rates '(record {start=1658351172; end=1658358172;})'
