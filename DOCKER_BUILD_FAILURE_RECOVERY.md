# Docker Build Failure - Diagnosis & Recovery Guide

## 🚨 THE ERROR

```
failed to solve: process "/bin/sh -c composer install --no-interaction 
--no-progress --prefer-dist --no-dev --optimize-autoloader" 
did not complete successfully: exit code: 2

Error response from daemon: pull access denied for vtigercrm-lo...
```

---

## 🔍 ROOT CAUSE ANALYSIS

### What Happened:

1. **Composer install failed** (exit code 2)
   - This is the real blocker
   - Composer couldn't install dependencies
   - Build stopped at this step

2. **Image pull failed** (secondary error)
   - Docker tried to use a cached image that doesn't exist
   - This is a consequence of the first failure
   - Not the root cause

### Why Composer Failed:

Common causes:
- ❌ Network timeout
- ❌ PHP memory limit
- ❌ Missing PHP extensions during build
- ❌ Corrupted package cache
- ❌ Dependency conflicts

---

## ✅ SOLUTION

### Step 1: Clean Up (Remove Everything)

```bash
# Stop any running containers
docker compose down -v 2>/dev/null || true

# Remove failed build
docker rmi vtigercrm-local:8.3.0 2>/dev/null || true

# Remove builder image
docker rmi vtigercrm-builder:8.3.0 2>/dev/null || true

# Clean docker buildkit cache
docker builder prune -a -f 2>/dev/null || true

echo "✓ Docker cleanup complete"
```

### Step 2: Increase Build Resources

Before rebuilding, ensure Docker has enough resources:

**For Docker Desktop (Mac/Windows):**
1. Open Docker Desktop settings
2. Go to Resources
3. Set Memory to: 4GB minimum
4. Set CPU to: 4 cores minimum
5. Click Apply & Restart

**For Linux:**
```bash
# Check available memory
free -h

# Should show at least 4GB available
```

### Step 3: Rebuild with Verbose Output

This time, we'll see exactly where it fails:

```bash
cd /path/to/vtiger-docker

# Rebuild with progress output
docker build \
  --progress=plain \
  --no-cache \
  --target builder \
  -t vtigercrm-builder:8.3.0 \
  -f Dockerfile . 2>&1 | tee build.log

# The 2>&1 | tee build.log captures ALL output to a file
```

This will take 10-15 minutes. Watch for the exact line where it fails.

### Step 4: Analyze the Build Log

After the build, examine what failed:

```bash
# Show the last 100 lines (where the error usually is)
tail -100 build.log

# Search for error keywords
grep -i "error\|failed\|fatal\|killed" build.log

# Search for composer errors
grep -A 5 "composer install" build.log
```

---

## 🎯 SPECIFIC SOLUTIONS BY ERROR

### If you see "Killed" or "Out of memory":

**The Problem:** Docker ran out of memory during composer install

**The Fix:**

```bash
# Increase PHP memory limit
export COMPOSER_MEMORY_LIMIT=-1

# Try building again
./build.sh --no-push
```

### If you see "connection refused" or "timeout":

**The Problem:** Network connection to packagist.org failed

**The Fix:**

```bash
# Clean composer cache
rm -rf ~/.composer/cache/*

# Try building again with retries
./build.sh --no-push
```

### If you see "Package not found" or "version constraint":

**The Problem:** Composer can't resolve dependencies

**The Fix:**

```bash
# This might mean the vtiger source is missing or corrupted
cd /path/to/vtiger-docker

# Check if the Dockerfile clones correctly
docker build --target builder -t vtigercrm-builder:debug --progress=plain \
  -f Dockerfile . 2>&1 | grep -A 5 "git clone"
```

---

## 🔧 MODIFIED BUILD SCRIPT

Create a more resilient build script:

```bash
#!/bin/bash
set -euo pipefail

log() { echo "[BUILD] $*"; }
err() { echo "[ERROR] $*" >&2; }

cd /path/to/vtiger-docker

log "Step 1: Clean up old builds..."
docker compose down -v 2>/dev/null || true
docker rmi vtigercrm-local:8.3.0 2>/dev/null || true
docker builder prune -a -f 2>/dev/null || true

log "Step 2: Set build environment..."
export COMPOSER_MEMORY_LIMIT=-1
export BUILDKIT_PROGRESS=plain

log "Step 3: Build builder stage..."
if ! docker build \
  --progress=plain \
  --no-cache \
  --target builder \
  -t vtigercrm-builder:8.3.0 \
  -f Dockerfile . 2>&1 | tee build-step1.log; then
  
  err "Builder stage failed!"
  log "Last 50 lines of output:"
  tail -50 build-step1.log
  exit 1
fi

log "Step 4: Build runtime stage..."
if ! docker build \
  --progress=plain \
  --target runtime \
  -t vtigercrm-local:8.3.0 \
  -f Dockerfile . 2>&1 | tee build-step2.log; then
  
  err "Runtime stage failed!"
  log "Last 50 lines of output:"
  tail -50 build-step2.log
  exit 1
fi

log "✓ Build successful!"
log "Image: vtigercrm-local:8.3.0"
log "Ready to run: docker compose up -d"
```

Save as `build-resilient.sh` and run:

```bash
chmod +x build-resilient.sh
./build-resilient.sh
```

---

## 📋 STEP-BY-STEP RECOVERY PLAN

### Phase 1: Diagnose (5 minutes)

```bash
# 1. Check Docker resources
docker system df

# 2. Check disk space
df -h /var/lib/docker

# 3. Clean system
docker system prune -a -f
docker volume prune -f

# 4. Verify Docker is working
docker run hello-world
```

### Phase 2: Prepare (2 minutes)

```bash
# 1. Navigate to repo
cd /path/to/vtiger-docker

# 2. Check Dockerfile is valid
docker build --dry-run . || echo "Dockerfile has issues"

# 3. Set environment
export COMPOSER_MEMORY_LIMIT=-1
export BUILDKIT_PROGRESS=plain
```

### Phase 3: Rebuild (20-30 minutes)

```bash
# Option A: Use the provided build script (simplest)
./build.sh --no-push

# Option B: Manual build with verbose output
docker build --progress=plain --no-cache -t vtigercrm-local:8.3.0 .

# Option C: Build with retry logic
for attempt in 1 2 3; do
  echo "Attempt $attempt/3..."
  if docker build --progress=plain -t vtigercrm-local:8.3.0 .; then
    echo "✓ Build succeeded!"
    break
  else
    echo "✗ Attempt $attempt failed, retrying..."
    docker builder prune -a -f
    sleep 10
  fi
done
```

### Phase 4: Verify (5 minutes)

```bash
# Check image exists
docker image ls | grep vtigercrm-local

# Start containers
docker compose up -d

# Check logs
docker compose logs -f

# Test access
sleep 60
curl http://localhost:8080
```

---

## 🆘 IF BUILD KEEPS FAILING

### Option A: Increase Docker Resource Limits

Edit your Docker daemon config:

**On Mac/Windows (Docker Desktop):**
- Settings → Resources
- Memory: 6GB (increased from 4GB)
- Swap: 2GB
- CPU: 4+

**On Linux (Edit `/etc/docker/daemon.json`):**

```json
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "memory": 6147483648,
  "memswap": 8589934592,
  "cpus": "4.0"
}
```

Then restart Docker:

```bash
sudo systemctl restart docker
```

### Option B: Build Without Cache

```bash
docker build --progress=plain --no-cache --target builder -t vtigercrm-builder:8.3.0 -f Dockerfile .
```

The `--no-cache` flag forces a complete rebuild, bypassing any corrupted cache.

### Option C: Debug Build Interactively

```bash
# Stop at the point where composer install happens
docker build --progress=plain --target builder -t vtigercrm-debug -f Dockerfile .

# Enter the container
docker run -it vtigercrm-debug /bin/bash

# Now you're inside the container, try composer manually
cd /app
composer install --no-interaction --no-progress --prefer-dist --no-dev --optimize-autoloader

# See exactly what error occurs
```

### Option D: Pre-download Dependencies

Create a custom Dockerfile that downloads composer dependencies separately:

```dockerfile
FROM php:8.3-apache-bookworm AS builder-with-cache

RUN apt-get update && apt-get install -y \
    git \
    curl \
    && docker-php-ext-install mysqli pdo_mysql

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /app

# Clone first
RUN git clone --depth=1 https://github.com/bighog300/vtigercrm.git .

# Install composer dependencies with retry logic
RUN for i in 1 2 3; do \
      composer install --no-interaction --no-progress --prefer-dist --no-dev --optimize-autoloader && break || \
      (echo "Attempt $i failed, retrying..."; sleep 10); \
    done
```

---

## 🎯 QUICK CHECKLIST

Before rebuilding:

- [ ] At least 4GB RAM available: `free -h`
- [ ] At least 10GB disk space: `df -h`
- [ ] Docker daemon is running: `docker ps`
- [ ] Network connection is active: `ping google.com`
- [ ] Set memory limit: `export COMPOSER_MEMORY_LIMIT=-1`
- [ ] Clean previous builds: `docker builder prune -a -f`
- [ ] No other Docker builds running: `docker ps -a`

---

## 📊 EXPECTED BUILD TIMELINE

```
Clone vtiger source:       1-2 min   (network dependent)
Install PHP extensions:    2-3 min   (system dependent)
Composer install:          5-10 min  ⚠️ (THIS IS WHERE IT FAILED)
                                        - Check network
                                        - Check memory
                                        - Check dependencies
Build runtime image:       2-3 min
─────────────────────────────
Total:                     15-25 min
```

---

## 🔄 RETRY STRATEGY

If build fails again:

**Attempt 1:** Full clean + rebuild
```bash
docker system prune -a -f
./build.sh --no-push
```

**Attempt 2:** Increase memory + no cache
```bash
export COMPOSER_MEMORY_LIMIT=-1
docker build --progress=plain --no-cache -t vtigercrm-local:8.3.0 .
```

**Attempt 3:** Debug interactively
```bash
docker build --progress=plain --target builder -t vtigercrm-debug -f Dockerfile .
docker run -it vtigercrm-debug composer install
```

**Attempt 4:** Manual step-by-step
```bash
# If automated build won't work, build locally:
git clone https://github.com/bighog300/vtigercrm.git vtigercrm-src
cd vtigercrm-src
composer install --no-dev --optimize-autoloader
# Then adjust Dockerfile to use local copy
```

---

## ✅ SUCCESS INDICATORS

When build completes successfully:

```
✓ Built image: vtigercrm-local:8.3.0
✓ Image size: ~800MB
✓ docker image ls shows the image
✓ No "Error" or "failed" messages
✓ Process completes with exit code 0
```

---

## 📞 IF YOU'RE STILL STUCK

Collect this diagnostic information:

```bash
# System info
echo "=== Docker Version ===" && docker --version
echo "=== Docker Resources ===" && docker system df
echo "=== Disk Space ===" && df -h
echo "=== Memory ===" && free -h
echo "=== CPU ===" && nproc

# Try a simple build
docker build --help | grep progress

# Check composer separately
docker run --rm -it composer:2 composer --version

# Save all this to a file
(docker --version; docker system df; df -h; free -h) > diagnostics.txt
```

Share this information if you need further help.

---

## 🎓 WHY COMPOSER INSTALL IS THE BOTTLENECK

Composer install downloads 300+ PHP packages and:
- ✅ Verifies package signatures
- ✅ Resolves dependencies
- ✅ Downloads autoloader
- ✅ Can require significant memory
- ✅ Network-dependent (needs packagist.org access)
- ✅ CPU-intensive (dependency resolution)

This is why it's the most likely failure point.

---

## 🚀 AFTER SUCCESSFUL BUILD

```bash
# Start containers
docker compose up -d

# Wait for initialization
sleep 60

# Verify running
docker compose ps

# Check logs
docker compose logs app

# Test access
curl http://localhost:8080

# Login
# Username: admin
# Password: Admin@1234
```

---

**Status:** Complete recovery guide provided  
**Next Step:** Run "Phase 1: Diagnose" above  
**Expected Result:** Successful build within 30 minutes  

