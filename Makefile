# Dungeon Master 64 - host build targets.
# Engine targets assemble the ACME test programs (Milestone 3). Game targets come with Milestone 5.

PY      := .venv/bin/python
MODEL   ?= baseline_bpe72_v3q
VERSION ?= dm64-$(MODEL)-01
CKPT    := models/checkpoints/$(MODEL)/best.pt
PKG     := models/exported/$(MODEL).d64ai

ACME    := acme -f cbm
TABLES  := engine/source/generated/exp_table.asm
ENGINE_SRC := $(wildcard engine/source/*.asm engine/include/*.inc) $(TABLES)

.PHONY: help venv dataset dataset-v2 dataset-v3 fact-check bench hw-bench test test-slow train train-bringup convert evaluate validate inspect sizing \
        engine profile ultimate ultimate-dry terminal hw-check hw-terminal game

help:
	@echo "make venv            create .venv (uv, Python 3.12) and install requirements.txt"
	@echo "make dataset         regenerate datasets/ from datasets/raw/phrasebank.yaml"
	@echo "make dataset-v2      v2 dataset: phrasebank.yaml + phrasebank_v2_additions.yaml (*_v2.jsonl)"
	@echo "make dataset-v3      v3 dataset: v2 + v3 phrases, fact-filtered, short game texts, typos"
	@echo "make test            run the test suite (Python + VICE engine tests, fast set)"
	@echo "make test-slow       also run the long VICE runs on the baseline model"
	@echo "make engine          assemble the engine test programs (ACME)"
	@echo "make profile         VICE cycle profile of the engine on \$$MODEL"
	@echo "make train           train MODEL (default baseline_bpe72_v3q; configs/\$$MODEL.yaml)"
	@echo "make train-bringup   train the tiny bring-up model"
	@echo "make convert         checkpoint -> models/exported/\$$MODEL.d64ai (+ manifest, tokens.inc)"
	@echo "make evaluate        float vs integer agreement report for \$$MODEL"
	@echo "make fact-check      game-style narration on the integer model: facts, variety, cut-offs"
	@echo "make validate        independent format check of \$$MODEL.d64ai"
	@echo "make inspect         print the package summary"
	@echo "make sizing          architecture size table (docs/ARCHITECTURE.md)"
	@echo "make terminal        assemble the AI terminal: terminal/build/dm64.prg"
	@echo "make bench           assemble the benchmark: bench/build/bench.prg (BENCH.PRG)"
	@echo "make hw-bench        run BENCH.PRG for 5 minutes on the C64 Ultimate and check it"
	@echo "make game            assemble the dungeon game: game/build/dm64game.prg"
	@echo "make hw-check        run the engine hardware check on the Ultimate (REST)"
	@echo "make hw-terminal     type a prompt into the terminal on the Ultimate (REST)"
	@echo "make ultimate        FTP release files to the Ultimate: <USB>/dist/dungeon-master/ (asks first)"
	@echo "make ultimate-dry    list what make ultimate would upload"

venv:
	uv venv --python 3.12 .venv
	uv pip install --python $(PY) -r requirements.txt

dataset:
	$(PY) tools/dataset_generator.py

dataset-v2:
	$(PY) tools/dataset_generator.py --extra datasets/raw/phrasebank_v2_additions.yaml --tag v2 --count 300000

dataset-v3:
	$(PY) tools/dataset_generator.py --extra datasets/raw/phrasebank_v2_additions.yaml \
		--extra datasets/raw/phrasebank_v3_additions.yaml --tag v3 --count 300000 \
		--fact-filter --max-game-tokens 44 --typos 0.3

test: engine terminal game
	$(PY) -m pytest -q

test-slow: engine
	$(PY) -m pytest -q -m "slow or not slow"

$(TABLES): tools/gen_engine_tables.py python/fixedpoint.py
	$(PY) tools/gen_engine_tables.py

engine/build/test_host.prg: engine/tests/test_host.asm $(ENGINE_SRC)
	@mkdir -p engine/build
	python3 tools/acme_longbranch.py $(ACME) -o $@ -l engine/build/test_host.lbl $<

engine/build/api_host.prg: engine/tests/api_host.asm $(ENGINE_SRC)
	@mkdir -p engine/build
	python3 tools/acme_longbranch.py $(ACME) -o $@ -l engine/build/api_host.lbl $<

engine: engine/build/test_host.prg engine/build/api_host.prg

TERM_TABLES := terminal/source/generated/scene_tables.asm
$(TERM_TABLES): tools/gen_terminal_tables.py python/vocab.py python/convert.py
	$(PY) tools/gen_terminal_tables.py

terminal/build/dm64.prg: terminal/source/terminal.asm $(TERM_TABLES) $(ENGINE_SRC)
	@mkdir -p terminal/build
	python3 tools/acme_longbranch.py $(ACME) -o $@ -l terminal/build/dm64.lbl $<

terminal: terminal/build/dm64.prg

BENCH_TABLES := bench/source/generated/bench_tables.asm
$(BENCH_TABLES): tools/bench.py python/vocab.py python/lexicon.py
	$(PY) tools/bench.py tables

bench/build/bench.prg: bench/source/bench.asm $(BENCH_TABLES) $(ENGINE_SRC)
	@mkdir -p bench/build
	python3 tools/acme_longbranch.py $(ACME) -o $@ -l bench/build/bench.lbl $<

bench: bench/build/bench.prg

GAME_TABLES := game/source/generated/game_tables.asm
$(GAME_TABLES): tools/gen_game_tables.py python/vocab.py python/facts.py
	$(PY) tools/gen_game_tables.py

game/build/dm64game.prg: $(wildcard game/source/*.asm) $(GAME_TABLES)
	@mkdir -p game/build
	python3 tools/acme_longbranch.py $(ACME) -o $@ -l game/build/dm64game.lbl game/source/game.asm

game: game/build/dm64game.prg

# Hardware runs on the C64 Ultimate (ULT_HOST). They reset the C64; the REU keeps its contents.
hw-check: engine
	$(PY) tools/hw_check.py --ultimate

hw-bench: bench
	$(PY) tools/bench.py ultimate --turbo

hw-terminal: terminal
	$(PY) tools/terminal_hw.py --exact

profile: engine
	$(PY) tools/engine_profile.py $(PKG)

train:
	$(PY) python/train.py --config configs/$(MODEL).yaml

train-bringup:
	$(PY) python/train.py --config configs/bringup.yaml

$(PKG): $(CKPT) python/convert.py python/quantize.py python/d64ai.py python/vocab.py
	$(PY) python/convert.py $(CKPT) --out $(PKG) --version $(VERSION)

convert: $(PKG)
	python3 tools/format_validator.py $(PKG)

evaluate: $(PKG)
	$(PY) python/evaluate.py $(CKPT) $(PKG)

fact-check: $(PKG)
	$(PY) tools/fact_check.py $(PKG) --int -n 60 --train datasets/training/train_v3.jsonl

validate:
	python3 tools/format_validator.py $(PKG)

inspect:
	$(PY) tools/model_inspector.py $(PKG)

sizing:
	python3 tools/arch_sizing.py

# Release files to the C64 Ultimate over FTP (host: ULT_HOST, default 192.168.10.148).
SHIP_MODEL := models/exported/baseline_bpe72_v3q.d64ai

ultimate: $(SHIP_MODEL) terminal game bench
	python3 tools/ultimate_upload.py

ultimate-dry: $(SHIP_MODEL) terminal game bench
	python3 tools/ultimate_upload.py --dry-run
