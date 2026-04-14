SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

GO_VERSION ?= 1.21.3
GO_CONTAINER_IMAGE ?= docker.io/library/golang:$(GO_VERSION)

# Use GOPROXY environment variable if set
GOPROXY := $(shell go env GOPROXY)
ifeq ($(GOPROXY),)
GOPROXY := https://proxy.golang.org
endif
export GOPROXY

# Active module mode, as we use go modules to manage dependencies
export GO111MODULE=on

# This option is for running docker manifest command
export DOCKER_CLI_EXPERIMENTAL := enabled

MACHINE := rancher

TAG ?= dev
ARCH ?= $(shell go env GOARCH)
ALL_ARCH = amd64 arm64 s390x
DEFAULT_PLATFORMS := linux/amd64,linux/arm64
REGISTRY ?= ghcr.io
ORG ?= rancher-sandbox
ACTION_IMAGE_NAME ?= aws-janitor
ACTION_IMG ?= $(REGISTRY)/$(ORG)/$(ACTION_IMAGE_NAME)
MANIFEST_IMG ?= $(ACTION_IMG)-$(ARCH)

REPO ?= rancher-sandbox
IMAGE ?= aws-janitor
IMAGE_NAME ?= $(REPO)/$(IMAGE):$(TAG)

.PHONY: test
test:
	go test ./...

.PHONY: build
build:
	go build -o bin/aws-janitor main.go

## --------------------------------------
## Docker
## --------------------------------------

.PHONY: docker-push
docker-push: ## Push the docker images
	docker push $(MANIFEST_IMG):$(TAG)

.PHONY: docker-push-all
docker-push-all: $(addprefix docker-push-,$(ALL_ARCH))  ## Push all the architecture docker images
	$(MAKE) docker-push-manifest-action

docker-push-%:
	$(MAKE) ARCH=$* docker-push

.PHONY: docker-push-manifest-action
docker-push-manifest-action: ## Push the multiarch manifest for the actions docker images
	## Minimum docker version 18.06.0 is required for creating and pushing manifest images.
	docker manifest create --amend $(ACTION_IMG):$(TAG) $(shell echo $(ALL_ARCH) | sed -e "s~[^ ]*~$(ACTION_IMG)\-&:$(TAG)~g")
	@for arch in $(ALL_ARCH); do docker manifest annotate --arch $${arch} ${ACTION_IMG}:${TAG} ${ACTION_IMG}-$${arch}:${TAG}; done
	docker manifest push --purge $(ACTION_IMG):$(TAG)

.PHONY: docker-pull-prerequisites
docker-pull-prerequisites:
	docker pull docker.io/docker/dockerfile:1.4
	docker pull $(GO_CONTAINER_IMAGE)
	docker pull gcr.io/distroless/static:latest

.PHONY: docker-build-all
docker-build-all: $(addprefix docker-build-,$(ALL_ARCH)) ## Build docker images for all architectures

docker-build-%:
	$(MAKE) ARCH=$* docker-build

.PHONY: docker-build
docker-build: docker-pull-prerequisites ## Run docker-build-* targets for all providers
	DOCKER_BUILDKIT=1 docker build --build-arg builder_image=$(GO_CONTAINER_IMAGE) --build-arg goproxy=$(GOPROXY) --build-arg ARCH=$(ARCH) --build-arg package=. --build-arg ldflags="$(LDFLAGS)" . -t $(MANIFEST_IMG):$(TAG)

docker-list-all:
	@echo $(CONTROLLER_IMG):${TAG}
	@for arch in $(ALL_ARCH); do echo $(ACTION_IMG)-$${arch}:${TAG}; done

## --------------------------------------
## Buildx / publish-image targets
## --------------------------------------

.PHONY: buildx-machine
buildx-machine: ## Create rancher buildx machine targeting DEFAULT_PLATFORMS.
	@docker buildx ls | grep $(MACHINE) || \
	  docker buildx create --name=$(MACHINE) --platform=$(DEFAULT_PLATFORMS)

.PHONY: push-image
push-image: ## Build and push multiarch image via docker buildx.
	docker buildx build \
	  $(IID_FILE_FLAG) \
	  $(BUILDX_ARGS) \
	  --platform=$(TARGET_PLATFORMS) \
	  --tag $(IMAGE_NAME) \
	  --push \
	  .

.PHONY: push-prime-image
push-prime-image: ## Build and push multiarch image to prime registry with SBOM and provenance attestations.
	BUILDX_ARGS="--sbom=true --attest type=provenance,mode=max" \
	$(MAKE) push-image