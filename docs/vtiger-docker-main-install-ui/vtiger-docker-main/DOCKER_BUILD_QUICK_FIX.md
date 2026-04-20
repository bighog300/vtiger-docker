# Docker Build Failure - QUICK FIX GUIDE

## 🎯 THE PROBLEM

Composer failed to install dependencies during Docker build:
```
composer install ... did not complete successfully: exit code: 2
```

This is a **common issue** - usually one of:
- Memory limit exceeded
- Network timeout
- Dependency conflict

---

## ⚡ QUICK FIX (3 steps, 5 minutes)

### Step 1: Clean Everything

```bash
cd /path/to/vtiger-docker

# Stop containers
docker compose down -v 2>/dev/null || true

# Remove failed images
docker rmi vtigercrm-local:8.3.0 2>/dev/null || true
docker rmi vtigercrm-builder:8.3.0 2>/dev/null || true

# Clean docker cache
docker builder prune -a -f 2>/dev/null || true

echo "✓ Cleaned"
```

### Step 2: Increase Memory & Try Again

```bash
# Set unlimited memory for composer
export COMPOSER_MEMORY_LIMIT=-1

# Try the build
./build.sh --no-push
```

**Expected:** Build takes 15-25 minutes. Watch for progress.

### Step 3: If That Fails - Try Without Cache

```bash
docker build --progress=plain --no-cache -t vtigercrm-local:8.3.0 -f Dockerfile .
```

---

## 🔍 IF IT STILL FAILS

Run this to see the exact error:

```bash
# Build with visible output
docker build --progress=plain --no-cache --target builder -t vtigercrm-builder:8.3.0 -f Dockerfile . 2>&1 | tail -100
```

Look for one of these errors:

### Error: "Killed" or "out of memory"

**Fix:** Increase Docker memory

**Docker Desktop (Mac/Windows):**
1. Open Docker Desktop settings
2. Resources → Memory: increase to 6GB
3. Click "Apply & Restart"
4. Retry build

**Linux:**
```bash
# Check available memory
free -h

# If less than 4GB, close other apps
# If 4GB+, the issue is Docker memory limit
```

### Error: "Network error" or "connection timeout"

**Fix:** Network is unstable

```bash
# Test network
ping -c 3 packagist.org

# If times out, check internet connection
# Then retry build
./build.sh --no-push
```

### Error: "Package not found" or "version conflict"

**Fix:** Dependency issue

```bash
# Clean composer cache
rm -rf ~/.composer/cache/*

# Retry
./build.sh --no-push
```

---

## 🛠️ ADVANCED: BUILD WITH RETRY LOGIC

Create a `build-retry.sh` script:

```bash
#!/bin/bash
set -e

export COMPOSER_MEMORY_LIMIT=-1

cd /path/to/vtiger-docker

for attempt in 1 2 3; do
  echo "🔨 Build attempt $attempt/3..."
  
  # Clean before each retry
  docker builder prune -a -f 2>/dev/null || true
  
  if ./build.sh --no-push; then
    echo "✅ Build successful!"
    exit 0
  else
    echo "❌ Attempt $attempt failed"
    if [ $attempt -lt 3 ]; then
      echo "⏳ Waiting 30 seconds before retry..."
      sleep 30
    fi
  fi
done

echo "❌ Build failed after 3 attempts"
exit 1
```

Run it:
```bash
chmod +x build-retry.sh
./build-retry.sh
```

---

## 📊 WHAT'S HAPPENING

The Docker build has these stages:

```
1. Start PHP container         ✅ Works
2. Install system packages     ✅ Works  
3. Install PHP extensions      ✅ Works
4. Git clone vtiger            ✅ Works
5. Composer install dependencies  ⚠️ FAILS HERE
6. Export database schema      (never reached)
7. Build runtime image         (never reached)
```

Stage 5 (composer) is failing because:
- Requires memory: 512MB+
- Requires network: access to packagist.org
- Requires time: 5-10 minutes
- Requires CPU: dependency resolution is intensive

---

## ✅ VERIFY RESOURCES BEFORE BUILDING

```bash
# Check memory
echo "Memory available:"
free -h | grep Mem

# Check disk space
echo "Disk space available:"
df -h | grep -E "docker|/$"

# Check Docker resources
echo "Docker limits:"
docker system df
```

**You need:**
- ✅ Memory: 4GB free minimum
- ✅ Disk: 10GB free
- ✅ Network: Stable internet

---

## 🎯 STEP-BY-STEP FROM SCRATCH

```bash
# 1. Navigate to repo
cd /path/to/vtiger-docker

# 2. Verify files exist
ls -la build.sh Dockerfile init-scripts/install.sh

# 3. Clean everything
docker system prune -a -f
docker volume prune -f

# 4. Set environment
export COMPOSER_MEMORY_LIMIT=-1

# 5. Build with verbose output (saves to file)
docker build --progress=plain --no-cache \
  -t vtigercrm-local:8.3.0 \
  -f Dockerfile . 2>&1 | tee build.log

# 6. If it fails, check the log
grep -i "error\|failed\|killed" build.log | head -20

# 7. If it succeeds, verify
docker image ls | grep vtigercrm

# 8. Deploy
docker compose up -d
```

---

## 🚨 NUCLEAR OPTION (Last Resort)

If nothing else works:

```bash
# Remove everything Docker
docker system prune -a -f --volumes

# Restart Docker daemon
sudo systemctl restart docker

# Or on Mac:
# Restart Docker Desktop

# Then retry build
./build.sh --no-push
```

⚠️ This removes ALL images and volumes, not just vtiger

---

## 📝 WHAT TO DO IF STUCK

**Collect this information:**

```bash
docker --version
docker system df
free -h
df -h
cat /path/to/build.log 2>/dev/null | head -50
docker logs vtigercrm-builder 2>/dev/null | tail -50
```

**Then:**
1. Run the 3-step quick fix again
2. If still failing, share the error from step 1 of advanced section
3. Try the nuclear option

---

## ⏱️ REALISTIC TIMELINE

- Quick fix setup: **2 minutes**
- Docker build: **15-25 minutes** (mostly waiting)
- Deploy: **5 minutes**
- Test: **5 minutes**
- **Total: 30-40 minutes**

---

## 🎯 SUCCESS LOOKS LIKE

When it works:

```
✓ vtigercrm-local:8.3.0 built successfully
✓ docker image ls shows the image (800MB+)
✓ docker compose up -d starts without errors
✓ curl http://localhost:8080 returns 200
✓ Login with admin / Admin@1234 works
```

---

## 🚀 AFTER SUCCESSFUL BUILD

```bash
# Start
docker compose up -d

# Wait for init
sleep 60

# Verify
docker compose ps
curl http://localhost:8080

# View logs
docker compose logs -f

# Login
# admin / Admin@1234
```

---

**Next Step:** Run the Quick Fix 3-step solution above.  
**Expected Result:** Build completes in 20-25 minutes.

