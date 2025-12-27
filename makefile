# Makefile for project automation
PROJECT_NAME ?= {{concern}}
EMACS ?= emacs
ORG_FILES := $(wildcard *.org */*.org)
JBAKE_JAR := jbake.jar  # Downloaded on-demand
DOCKER_IMAGE := emacs-mu4e  # Custom image for mu4e
SUBDIRS := architecture adr bugs emails meetings notes rcas tasks  # For auto-includes

# Auto-detect GitHub repository from git remote
GIT_REMOTE_URL := $(shell git config --get remote.origin.url 2>/dev/null)
GITHUB_REPO := $(shell echo "$(GIT_REMOTE_URL)" | sed -E 's#.*github\.com[:/]([^/]+/[^.]+)(\.git)?$$#\1#')

# GitHub Pages deployment directory (can be overridden with: make deploy-site GH_PAGES_DIR=/custom/path)
GH_PAGES_DIR ?= site/output

# Init: Create directories, basic files, and JBake setup
init:
	mkdir -p $(SUBDIRS) code resources site/assets site/content site/templates site/output
	touch $(addsuffix .org,$(SUBDIRS)) emails.org $(PROJECT_NAME).org site/jbake.properties
	echo "site.title=$(PROJECT_NAME)" > site/jbake.properties  # Basic JBake config
	echo "<html><body><h1>{{title}}</h1>{{{content}}}</body></html>" > site/templates/index.ftl  # Simple template
	git submodule init  # For code/
	@echo "Initialized. Customize site/templates as needed."

# 1. Auto-update #+include in consolidations (e.g., for tasks.org, add lines for tasks/*.org)
update-includes:
	@for dir in $(SUBDIRS); do \
		consol=$$dir.org; \
		echo "* All $$dir" > $$consol.tmp; \
		for file in $$dir/*.org; do \
			echo "#+include: \"$$file\" :only-contents t" >> $$consol.tmp; \
		done; \
		mv $$consol.tmp $$consol; \
	done
	@echo "Consolidation files updated with #+include lines."

# 2. Build JBake site: Export Org to MD, then build
build-site: export-org-to-md
	@if [ ! -f $(JBAKE_JAR) ]; then curl -O https://jbake.org/files/jbake-2.6.7-bin.zip && unzip jbake-2.6.7-bin.zip && mv jbake-2.6.7-bin/jbake.jar . && rm -rf jbake-2.6.7-bin*; fi
	java -jar $(JBAKE_JAR) -b site  # Bake from site/ to site/output
	@echo "Site built in site/output. Serve with 'make serve-site'."

export-org-to-md:
	$(EMACS) --batch --eval "(require 'org)" $(PROJECT_NAME).org -f org-md-export-to-markdown  # Export dashboard to site/content/index.md
	@for file in $(addsuffix .org,$(SUBDIRS)); do \
		$(EMACS) --batch --eval "(require 'org)" $$file -f org-md-export-to-markdown; \
		mv $${file%.org}.md site/content/; \
	done
	@echo "Org files exported to Markdown in site/content."

serve-site:
	cd site/output && python3 -m http.server 8000  # Simple local server

# 3. Sync bugs with GitHub issues (creates individual bug files in bugs/* directory)
sync-bugs:
	@if [ -z "$(GITHUB_REPO)" ]; then \
		echo "Error: No GitHub remote detected."; \
		echo "  Either: git remote add origin https://github.com/owner/repo.git"; \
		echo "  Or run: make sync-bugs GITHUB_REPO=owner/repo"; \
		exit 1; \
	fi
	@command -v gh >/dev/null 2>&1 || { echo "Error: GitHub CLI (gh) required. Run 'make install-deps'"; exit 1; }
	@command -v jq >/dev/null 2>&1 || { echo "Error: jq required. Run 'make install-deps'"; exit 1; }
	@echo "Syncing issues from: $(GITHUB_REPO)"
	@mkdir -p bugs/
	@gh issue list --repo $(GITHUB_REPO) --state all --json number,title,body,state,labels,createdAt --limit 100 | \
	jq -c '.[]' | while read -r issue; do \
		num=$$(echo "$$issue" | jq -r '.number'); \
		title=$$(echo "$$issue" | jq -r '.title' | sed 's/"/\\"/g'); \
		body=$$(echo "$$issue" | jq -r '.body // ""' | sed 's/"/\\"/g'); \
		state=$$(echo "$$issue" | jq -r '.state'); \
		created=$$(echo "$$issue" | jq -r '.createdAt'); \
		labels=$$(echo "$$issue" | jq -r '.labels[].name' | tr '\n' ':' | sed 's/ /_/g;s/^/:/;s/:$$//'); \
		file="bugs/bug-$$num.org"; \
		{ \
			echo "#+title: Bug #$$num: $$title"; \
			echo "#+filetags: :bug$$labels:"; \
			echo "#+created: $$created"; \
			echo "#+state: $$state"; \
			echo ""; \
			echo "* Bug #$$num: $$title"; \
			echo ":PROPERTIES:"; \
			echo ":GITHUB_ISSUE: $$num"; \
			echo ":STATE: $$state"; \
			echo ":END:"; \
			echo ""; \
			echo "** Description"; \
			echo "$$body"; \
		} > "$$file"; \
		echo "  Created: $$file"; \
	done
	@echo "✓ Issues synced to bugs/* directory"
	@echo "Note: Run 'make update-includes' to update bugs.org references"

# 4. Manage Git submodules in code/
submodules-init:
	git submodule update --init --recursive code/
	@echo "Submodules initialized."

submodules-sync:
	git submodule foreach git pull origin main  # Or your branch
	@echo "Submodules synced."

# 5. Run mu4e in Docker for email sync (build image if needed)
build-mu4e-docker:
	docker build -t $(DOCKER_IMAGE) - <<EOF
	FROM alpine:latest
	RUN apk add --no-cache emacs git mu isync msmtp ca-certificates
	RUN emacs --batch --eval "(require 'package)" --eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\"))" --eval "(package-initialize)" --eval "(package-install 'mu4e)"
	EOF

sync-emails-docker: build-mu4e-docker
	docker run -v $(PWD)/emails:/emails -v ~/.mbsyncrc:/root/.mbsyncrc $(DOCKER_IMAGE) sh -c "mbsync -a && mu index --maildir=/emails && emacs --batch --eval '(require \"mu4e\")' --eval '(mu4e-update-index)'"
	@echo "Emails synced via Dockerized mu4e."

# 6. Additional brainstormed targets
export-pdf:
	$(EMACS) --batch --eval "(require 'org)" $(PROJECT_NAME).org -f org-latex-export-to-pdf
	@echo "Dashboard exported to PDF."

lint-org:
	@for file in $(ORG_FILES); do \
		$(EMACS) --batch --eval "(require 'org)" --eval "(find-file \"$$file\")" --eval "(unless (org-mode-p) (error \"Not Org file\"))" --eval "(org-lint)" || echo "Lint issues in $$file"; \
	done
	@echo "Org files linted."

generate-diagrams:
	$(EMACS) --batch $(ORG_FILES) -f org-babel-tangle  # Tangle PlantUML blocks
	java -jar plantuml.jar *.pu  # Assumes PlantUML JAR; generate PNGs
	@echo "Diagrams generated."

archive-completed:
	find tasks/ -name "*.org" -exec grep -q "DONE" {} \; -exec mv {} tasks/archive/ \;
	@echo "Completed tasks archived."

generate-report:
	$(EMACS) --batch --eval "(org-agenda nil \"t\")" --eval "(org-agenda-write \"todo-report.txt\")"
	@echo "TODO report generated."

backup-git:
	git add . && git commit -m "Auto-backup" && git push
	@echo "Project backed up to Git."

deploy-site:
	@if [ ! -d "site/output" ] || [ -z "$$(ls -A site/output 2>/dev/null)" ]; then \
		echo "Error: site/output is empty. Run 'make build-site' first."; \
		exit 1; \
	fi
	@if [ -z "$(GITHUB_REPO)" ]; then \
		echo "Error: No GitHub remote detected. Run: git remote add origin <url>"; \
		exit 1; \
	fi
	@echo "Deploying to gh-pages branch..."
	@rm -rf .tmp-gh-pages
	@git clone --depth 1 --branch gh-pages $(GIT_REMOTE_URL) .tmp-gh-pages || \
		(echo "gh-pages branch doesn't exist. Creating..." && \
		 git clone --depth 1 $(GIT_REMOTE_URL) .tmp-gh-pages && \
		 cd .tmp-gh-pages && \
		 git checkout --orphan gh-pages && \
		 git rm -rf . 2>/dev/null || true)
	@cp -r site/output/* .tmp-gh-pages/
	@cd .tmp-gh-pages && \
		git add . && \
		git commit -m "Deploy site: $$(date '+%Y-%m-%d %H:%M:%S')" && \
		git push origin gh-pages
	@rm -rf .tmp-gh-pages
	@echo "✓ Site deployed to gh-pages branch"
	@echo "  Enable in repo Settings → Pages → Source: gh-pages branch"

ai-suggest:
	curl -s -X POST http://localhost:11434/api/generate -d '{"model": "llama3", "prompt": "Suggest content for $(TYPE) in project $(PROJECT_NAME)"}' > new-$(TYPE).org  # Local Ollama AI

run-tests:
	@for repo in code/*; do \
		cd $$repo && pytest || echo "Tests failed in $$repo"; \
	done
	@echo "Code tests run."

# All: Common workflow
all: init update-includes submodules-sync sync-emails-docker sync-bugs build-site

.PHONY: init update-includes build-site export-org-to-md serve-site sync-bugs submodules-init submodules-sync build-mu4e-docker sync-emails-docker export-pdf lint-org generate-diagrams archive-completed generate-report backup-git deploy-site ai-suggest run-tests all


# Watch: Auto-run on changes (uses inotifywait on Linux, fswatch on macOS)
# Install: Linux - sudo apt install inotify-tools; macOS - brew install fswatch
watch:
	@if [ "$(shell uname)" = "Linux" ]; then \
		if ! command -v inotifywait >/dev/null; then echo "Install inotify-tools"; exit 1; fi; \
		while true; do inotifywait -e modify $(ORG_FILES); make roam-rebuild agenda-export; done; \
	elif [ "$(shell uname)" = "Darwin" ]; then \
		if ! command -v fswatch >/dev/null; then echo "Install fswatch (brew install fswatch)"; exit 1; fi; \
		while true; do fswatch -1 $(ORG_FILES); make roam-rebuild agenda-export; done; \
	else \
		echo "Unsupported OS for watch: $(shell uname)"; exit 1; \
	fi


# Makefile for project automation
# Required Tools:
# - Emacs: Core for Org processing (install: sudo apt install emacs / brew install emacs)
# - inotify-tools (Linux for watch): sudo apt install inotify-tools
# - fswatch (macOS for watch): brew install fswatch
# - Java & PlantUML JAR (for diagrams): Download from plantuml.com
# - curl (for AI/api calls): Usually pre-installed
# Run 'make check-deps' to verify; 'make install-deps' to attempt auto-install (OS-specific)

PROJECT_NAME ?= {{concern}}
EMACS ?= emacs
ORG_FILES := $(wildcard *.org */*.org)

# Dependency lists (expand as needed)
COMMON_DEPS := emacs curl jq gh
LINUX_DEPS := inotify-tools
MAC_DEPS := fswatch

check-deps:
	@for dep in $(COMMON_DEPS); do command -v $$dep >/dev/null || echo "Missing: $$dep"; done
	@if [ "$(shell uname)" = "Linux" ]; then for dep in $(LINUX_DEPS); do command -v $$dep >/dev/null || echo "Missing (Linux): $$dep"; done; fi
	@if [ "$(shell uname)" = "Darwin" ]; then for dep in $(MAC_DEPS); do command -v $$dep >/dev/null || echo "Missing (macOS): $$dep"; done; fi
	@echo "Dependency check complete. Install missing ones manually if needed."

install-deps:
	@if [ "$(shell uname)" = "Linux" ]; then sudo apt update && sudo apt install -y $(COMMON_DEPS) $(LINUX_DEPS); \
	elif [ "$(shell uname)" = "Darwin" ]; then brew install $(COMMON_DEPS) $(MAC_DEPS); \
	else echo "Unsupported OS for auto-install"; exit 1; fi
	@echo "Dependencies installed (PlantUML/Java manual)."

init: install-deps check-deps
	mkdir -p architecture adr bugs code emails meetings notes rcas resources tasks site/assets site/content site/templates site/output scripts .templates
	# ... (rest of init as before)

# Add validation target
validate:
	@echo "Validating project structure..."
	@test -f $(PROJECT_NAME).org || (echo "ERROR: Dashboard missing" && exit 1)
	@test -d architecture || (echo "ERROR: architecture/ missing" && exit 1)
	# Add more checks

# Add pre-commit hook installation
hooks:
	echo "make validate" > .git/hooks/pre-commit
	chmod +x .git/hooks/pre-commit

# Current sync-code is too aggressive
sync-code:
	@for repo in code/*/; do \
		if [ -d "$$repo/.git" ]; then \
			echo "Updating $$repo..."; \
			(cd "$$repo" && git fetch --all && git status); \
		fi; \
	done

# Enhanced backup with rotation
backup:
	@backup_name="$(PROJECT_NAME)-$(shell date +%Y%m%d-%H%M%S).tar.gz"
	@tar -czf backups/$$backup_name --exclude=code --exclude=backups .
	@find backups -name "$(PROJECT_NAME)-*.tar.gz" -mtime +30 -delete
	@echo "Backup created: $$backup_name"

