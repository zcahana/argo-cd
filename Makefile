PACKAGE=github.com/argoproj/argo-cd
CURRENT_DIR=$(shell pwd)
DIST_DIR=${CURRENT_DIR}/dist
CLI_NAME=argocd

VERSION=$(shell cat ${CURRENT_DIR}/VERSION)
BUILD_DATE=$(shell date -u +'%Y-%m-%dT%H:%M:%SZ')
GIT_COMMIT=$(shell git rev-parse HEAD)
GIT_TAG=$(shell if [ -z "`git status --porcelain`" ]; then git describe --exact-match --tags HEAD 2>/dev/null; fi)
GIT_TREE_STATE=$(shell if [ -z "`git status --porcelain`" ]; then echo "clean" ; else echo "dirty"; fi)
PACKR_CMD=$(shell if [ "`which packr`" ]; then echo "packr"; else echo "go run vendor/github.com/gobuffalo/packr/packr/main.go"; fi)

override LDFLAGS += \
  -X ${PACKAGE}.version=${VERSION} \
  -X ${PACKAGE}.buildDate=${BUILD_DATE} \
  -X ${PACKAGE}.gitCommit=${GIT_COMMIT} \
  -X ${PACKAGE}.gitTreeState=${GIT_TREE_STATE}

# docker image publishing options
DOCKER_PUSH=false
IMAGE_TAG=latest
ifneq (${GIT_TAG},)
IMAGE_TAG=${GIT_TAG}
LDFLAGS += -X ${PACKAGE}.gitTag=${GIT_TAG}
endif
ifneq (${IMAGE_NAMESPACE},)
override LDFLAGS += -X ${PACKAGE}/install.imageNamespace=${IMAGE_NAMESPACE}
endif
ifneq (${IMAGE_TAG},)
override LDFLAGS += -X ${PACKAGE}/install.imageTag=${IMAGE_TAG}
endif

ifeq (${DOCKER_PUSH},true)
ifndef IMAGE_NAMESPACE
$(error IMAGE_NAMESPACE must be set to push images (e.g. IMAGE_NAMESPACE=argoproj))
endif
endif

ifdef IMAGE_NAMESPACE
IMAGE_PREFIX=${IMAGE_NAMESPACE}/
endif

.PHONY: all
all: cli image argocd-util

.PHONY: protogen
protogen:
	./hack/generate-proto.sh

.PHONY: clientgen
clientgen:
	./hack/update-codegen.sh

.PHONY: codegen
codegen: protogen clientgen

# NOTE: we use packr to do the build instead of go, since we embed .yaml files into the go binary.
# This enables ease of maintenance of the yaml files.
.PHONY: cli
cli: clean-debug
	${PACKR_CMD} build -v -i -ldflags '${LDFLAGS} -extldflags "-static"' -o ${DIST_DIR}/${CLI_NAME} ./cmd/argocd

.PHONY: cli-linux
cli-linux: clean-debug
	docker build --iidfile /tmp/argocd-linux-id --target argocd-build --build-arg MAKE_TARGET="cli CLI_NAME=argocd-linux-amd64" .
	docker create --name tmp-argocd-linux `cat /tmp/argocd-linux-id`
	docker cp tmp-argocd-linux:/go/src/github.com/argoproj/argo-cd/dist/argocd-linux-amd64 dist/
	docker rm tmp-argocd-linux

.PHONY: cli-darwin
cli-darwin: clean-debug
	docker build --iidfile /tmp/argocd-darwin-id --target argocd-build --build-arg MAKE_TARGET="cli GOOS=darwin CLI_NAME=argocd-darwin-amd64" .
	docker create --name tmp-argocd-darwin `cat /tmp/argocd-darwin-id`
	docker cp tmp-argocd-darwin:/go/src/github.com/argoproj/argo-cd/dist/argocd-darwin-amd64 dist/
	docker rm tmp-argocd-darwin

.PHONY: argocd-util
argocd-util: clean-debug
	CGO_ENABLED=0 go build -v -i -ldflags '${LDFLAGS} -extldflags "-static"' -o ${DIST_DIR}/argocd-util ./cmd/argocd-util

.PHONY: manifests
manifests:
	./hack/update-manifests.sh

.PHONY: server
server: clean-debug
	CGO_ENABLED=0 ${PACKR_CMD} build -v -i -ldflags '${LDFLAGS}' -o ${DIST_DIR}/argocd-server ./cmd/argocd-server
	
.PHONY: repo-server
repo-server:
	CGO_ENABLED=0 go build -v -i -ldflags '${LDFLAGS}' -o ${DIST_DIR}/argocd-repo-server ./cmd/argocd-repo-server

.PHONY: controller
controller:
	CGO_ENABLED=0 go build -v -i -ldflags '${LDFLAGS}' -o ${DIST_DIR}/argocd-application-controller ./cmd/argocd-application-controller

.PHONY: image
image:
	docker build -t $(IMAGE_PREFIX)argocd:$(IMAGE_TAG)  .
	@if [ "$(DOCKER_PUSH)" = "true" ] ; then docker push $(IMAGE_PREFIX)argocd:$(IMAGE_TAG) ; fi

.PHONY: builder-image
builder-image:
	docker build  -t $(IMAGE_PREFIX)argo-cd-ci-builder:$(IMAGE_TAG) --target builder .

.PHONY: lint
lint:
	gometalinter.v2 --config gometalinter.json ./...

.PHONY: test
test:
	go test -v -covermode=count -coverprofile=coverage.out `go list ./... | grep -v "github.com/argoproj/argo-cd/test/e2e"`

.PHONY: test-e2e
test-e2e:
	go test -v -failfast -timeout 20m ./test/e2e

# Cleans VSCode debug.test files from sub-dirs to prevent them from being included in packr boxes
.PHONY: clean-debug
clean-debug:
	-find ${CURRENT_DIR} -name debug.test | xargs rm -f

.PHONY: clean
clean: clean-debug
	-rm -rf ${CURRENT_DIR}/dist

.PHONY: precheckin
precheckin: test lint

.PHONY: release-precheck
release-precheck: manifests
	@if [ "$(GIT_TREE_STATE)" != "clean" ]; then echo 'git tree state is $(GIT_TREE_STATE)' ; exit 1; fi
	@if [ -z "$(GIT_TAG)" ]; then echo 'commit must be tagged to perform release' ; exit 1; fi
	@if [ "$(GIT_TAG)" != "v`cat VERSION`" ]; then echo 'VERSION does not match git tag'; exit 1; fi

.PHONY: release
release: release-precheck precheckin cli-darwin cli-linux image
