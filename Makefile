.PHONY: test lint deploy deploy-exit

# All shell tests; no server needed.
test:
	./scripts/lib_test.sh
	./scripts/tunnel-keys_test.sh
	./scripts/client-conf_test.sh
	./scripts/vpnctl_test.sh </dev/null
	./deploy/install_test.sh
	./deploy/awg0-init_test.sh
	./deploy/vpn-peer_test.sh
	./deploy/vpn-routes_test.sh
	./deploy/exit/install_test.sh
	./deploy/exit/exit-fw_test.sh

lint:
	shellcheck scripts/*.sh deploy/*.sh deploy/exit/*.sh

# Entry server (secret/entry-access.yaml). Needs secret/tunnel.yaml.
deploy:
	./scripts/deploy.sh

# Exit server (secret/exit-access.yaml). Creates secret/tunnel.yaml if it is missing.
deploy-exit:
	./scripts/deploy-exit.sh
