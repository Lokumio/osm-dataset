SHELL := /bin/bash
DOCKER := $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)

EXTRACT ?= krakow

.PHONY: help dataset dataset-all db-up db-down db-shell clean-work clean-dataset

help:
	@echo "make dataset EXTRACT=krakow   ~5 min,  ~80 MB working database"
	@echo "make dataset EXTRACT=pl20     ~35 min, ~3.4 GB working database"
	@echo "make dataset-all              both, one after the other"
	@echo ""
	@echo "make db-up / db-down / db-shell   the working PostGIS container"
	@echo "make clean-work                   drop the cached PBF downloads"
	@echo "make clean-dataset                drop the built dumps"
	@echo ""
	@echo "Output: dataset/<extract>/<date>/{neighbourhood.dump,manifest.json}"

dataset:
	scripts/build.sh $(EXTRACT)

# Both sets come off the same pipeline and differ only in the extract polygon.
# Built separately, the development set would stop saying anything about production.
dataset-all:
	scripts/build.sh krakow
	scripts/build.sh pl20

db-up:
	$(DOCKER) compose up -d

db-down:
	$(DOCKER) compose stop

db-shell:
	$(DOCKER) exec -it osm-dataset-postgis psql -U osmdata -d osm_build_$(EXTRACT)

clean-work:
	rm -rf work

clean-dataset:
	rm -rf dataset
