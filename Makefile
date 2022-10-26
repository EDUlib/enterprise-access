.DEFAULT_GOAL := help

.PHONY: help clean piptools requirements ci_requirements dev_requirements \
        validation_requirements doc_requirementsprod_requirements static shell \
        test coverage isort_check isort style lint quality pii_check validate \
        migrate html_coverage upgrade extract_translation dummy_translations \
        compile_translations fake_translations  pull_translations \
        push_translations start-devstack open-devstack  pkg-devstack \
        detect_changed_source_translations validate_translations check_keywords

define BROWSER_PYSCRIPT
import os, webbrowser, sys
try:
	from urllib import pathname2url
except:
	from urllib.request import pathname2url

webbrowser.open("file://" + pathname2url(os.path.abspath(sys.argv[1])))
endef
export BROWSER_PYSCRIPT
BROWSER := python -c "$$BROWSER_PYSCRIPT"

# Generates a help message. Borrowed from https://github.com/pydanny/cookiecutter-djangopackage.
help: ## display this help message
	@echo "Please use \`make <target>\` where <target> is one of"
	@awk -F ':.*?## ' '/^[a-zA-Z]/ && NF==2 {printf "\033[36m  %-25s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST) | sort

clean: ## delete generated byte code and coverage reports
	find . -name '*.pyc' -delete
	coverage erase
	rm -rf assets
	rm -rf pii_report

piptools: ## install pinned version of pip-compile and pip-sync
	pip install -r requirements/pip-tools.txt

clean_pycrypto: ## temporary (?) hack to deal with the pycrypto dep that's installed via setup-tools
	ls -d /usr/lib/python3/dist-packages/* | grep 'pycrypto\|pygobject\|pyxdg' | xargs rm -f

requirements: clean_pycrypto piptools dev_requirements ## sync to default requirements

ci_requirements: validation_requirements ## sync to requirements needed for CI checks

dev_requirements: ## sync to requirements for local development
	pip-sync -q requirements/dev.txt

validation_requirements: ## sync to requirements for testing & code quality checking
	pip-sync -q requirements/validation.txt

doc_requirements:
	pip-sync -q requirements/doc.txt

prod_requirements: ## install requirements for production
	pip-sync -q requirements/production.txt

static: ## generate static files
	python manage.py collectstatic --noinput

shell: ## run Django shell
	python manage.py shell

test: clean ## run tests and generate coverage report
	pytest --ds=enterprise_access.settings.test

# To be run from CI context
coverage: clean
	pytest --cov-report html
	$(BROWSER) htmlcov/index.html

isort_check: ## check that isort has been run
	isort --check-only -rc enterprise_access/

isort: ## run isort to sort imports in all Python files
	isort --recursive --atomic enterprise_access/

style: ## run Python style checker
	pylint --rcfile=pylintrc enterprise_access *.py

lint: ## run Python code linting
	pylint --rcfile=pylintrc enterprise_access *.py

quality: style isort_check lint ## check code style and import sorting, then lint

quality_fix: style isort lint ## Check code style, FIX any imports, then lint

pii_check: ## check for PII annotations on all Django models
	DJANGO_SETTINGS_MODULE=enterprise_access.settings.test \
	code_annotations django_find_annotations --config_file .pii_annotations.yml --lint --report --coverage

check_keywords: ## Scan the Django models in all installed apps in this project for restricted field names
	python manage.py check_reserved_keywords --override_file db_keyword_overrides.yml

validate: test quality pii_check check_keywords ## run tests, quality, and PII annotation checks

migrate: ## apply database migrations
	python manage.py migrate

html_coverage: ## generate and view HTML coverage report
	coverage html && open htmlcov/index.html

upgrade: export CUSTOM_COMPILE_COMMAND=make upgrade
upgrade: piptools ## update the requirements/*.txt files with the latest packages satisfying requirements/*.in
	# Make sure to compile files after any other files they include!
	pip-compile --allow-unsafe --rebuild --upgrade -o requirements/pip.txt requirements/pip.in
	pip-compile --upgrade -o requirements/pip-tools.txt requirements/pip-tools.in
	pip install -qr requirements/pip.txt
	pip install -qr requirements/pip-tools.txt
	pip-compile --upgrade -o requirements/base.txt requirements/base.in
	pip-compile --upgrade -o requirements/test.txt requirements/test.in
	pip-compile --upgrade -o requirements/doc.txt requirements/doc.in
	pip-compile --upgrade -o requirements/quality.txt requirements/quality.in
	pip-compile --upgrade -o requirements/validation.txt requirements/validation.in
	pip-compile --upgrade -o requirements/dev.txt requirements/dev.in
	pip-compile --upgrade -o requirements/production.txt requirements/production.in
	# Let tox control the Django version for tests
	grep -e "^django==" requirements/base.txt > requirements/django.txt
	sed '/^[dD]jango==/d' requirements/test.txt > requirements/test.tmp
	mv requirements/test.tmp requirements/test.txt

extract_translations: ## extract strings to be translated, outputting .mo files
	python manage.py makemessages -l en -v1 -d django
	python manage.py makemessages -l en -v1 -d djangojs

dummy_translations: ## generate dummy translation (.po) files
	cd enterprise_access && i18n_tool dummy

compile_translations: # compile translation files, outputting .po files for each supported language
	python manage.py compilemessages

fake_translations: ## generate and compile dummy translation files

pull_translations: ## pull translations from Transifex
	tx pull -t -af --mode reviewed

push_translations: ## push source translation files (.po) from Transifex
	tx push -s

start-devstack: ## run a local development copy of the server
	docker-compose --x-networking up

open-devstack: ## open a shell on the server started by start-devstack
	docker exec -it enterprise-access /edx/app/enterprise-access/devstack.sh open

pkg-devstack: ## build the enterprise-access image from the latest configuration and code
	docker build -t enterprise-access:latest -f docker/build/enterprise-access/Dockerfile git://github.com/edx/configuration

detect_changed_source_translations: ## check if translation files are up-to-date
	cd enterprise_access && i18n_tool changed

validate_translations: fake_translations detect_changed_source_translations ## install fake translations and check if translation files are up-to-date

docker_build:
	docker build . -f Dockerfile --target app -t openedx/enterprise-access
	docker build . -f Dockerfile --target app -t openedx/enterprise-access.worker
	docker build . -f Dockerfile --target newrelic -t openedx/enterprise-access:latest-newrelic

	docker build . -f Dockerfile --target devstack -t openedx/enterprise-access:latest-devstack
	docker build . -f Dockerfile --target devstack -t openedx/enterprise-access.worker:latest-devstack

travis_docker_tag: docker_build
	docker tag openedx/enterprise-access openedx/enterprise-access:$$TRAVIS_COMMIT
	docker tag openedx/enterprise-access:latest-newrelic openedx/enterprise-access:$$TRAVIS_COMMIT-newrelic

travis_docker_auth:
	echo "$$DOCKER_PASSWORD" | docker login -u "$$DOCKER_USERNAME" --password-stdin

travis_docker_push: travis_docker_tag travis_docker_auth ## push to docker hub
	docker push 'openedx/enterprise-access:latest'
	docker push "openedx/enterprise-access:$$TRAVIS_COMMIT"
	docker push 'openedx/enterprise-access:latest-newrelic'
	docker push "openedx/enterprise-access:$$TRAVIS_COMMIT-newrelic"

dev.provision:
	bash ./provision-enterprise-access.sh

# devstack-themed shortcuts
dev.up: # Starts all containers
	docker-compose up -d

dev.up.build: docker_build
	docker-compose up -d

dev.down: # Kills containers and all of their data that isn't in volumes
	docker-compose down

dev.stop: # Stops containers so they can be restarted
	docker-compose stop

dev.backup: dev.up
	docker run --rm --volumes-from enterprise_access.db -v $$(pwd)/.dev/backups:/backup debian:jessie tar zcvf /backup/mysql57.tar.gz /var/lib/mysql

dev.restore: dev.up
	docker run --rm --volumes-from enterprise_access.db -v $$(pwd)/.dev/backups:/backup debian:jessie tar zxvf /backup/mysql57.tar.gz

app-shell: # Run the app shell as root
	docker exec -u 0 -it enterprise_access.app bash

db-shell: # Run the app shell as root, enter the app's database
	docker exec -u 0 -it enterprise_access.db mysql -u root enterprise_access

%-logs: # View the logs of the specified service container
	docker-compose logs -f --tail=500 $*

%-restart: # Restart the specified service container
	docker-compose restart $*

%-attach:
	docker attach enterprise_access.$*

%-shell: # Run a shell, as root, on the specified service container
	docker exec -u 0 -it enterprise_access.$* bash

github_docker_build:
	docker build . -f Dockerfile --target app -t openedx/enterprise-access
	docker build . -f Dockerfile --target newrelic -t openedx/enterprise-access:latest-newrelic

github_docker_tag: github_docker_build
	docker tag openedx/enterprise-access openedx/enterprise-access:${GITHUB_SHA}
	docker tag openedx/enterprise-access:latest-newrelic openedx/enterprise-access:${GITHUB_SHA}-newrelic

github_docker_auth:
	echo "$$DOCKERHUB_PASSWORD" | docker login -u "$$DOCKERHUB_USERNAME" --password-stdin

github_docker_push: github_docker_tag github_docker_auth ## push to docker hub
	docker push 'openedx/enterprise-access:latest'
	docker push "openedx/enterprise-access:${GITHUB_SHA}"
	docker push 'openedx/enterprise-access:latest-newrelic'
	docker push "openedx/enterprise-access:${GITHUB_SHA}-newrelic"

selfcheck: ## check that the Makefile is well-formed
	@echo "The Makefile is well-formed."
