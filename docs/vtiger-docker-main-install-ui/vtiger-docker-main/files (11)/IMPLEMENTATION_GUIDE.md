# Step2 Fix: Implementation & Testing Guide

## 🔧 Quick Start

### Apply the Patch

```bash
# Option 1: Use the unified diff
patch -p0 < step2.patch

# Option 2: Manual edit
# Edit: init-scripts/install.sh
# Lines: 628-647
# See step2.patch for exact changes
```

### Verify the Change

```bash
# Check that Step2 handling uses --get flag
grep -A 15 'if \[ "${previous_step_mode}" = "Step2" \]' init-scripts/install.sh | head -20
```

Expected output should show:
```bash
if [ "${previous_step_mode}" = "Step2" ]; then
  log "Step2 is a license agreement (GET form, no data submission)."
  log "Form method=get; proceeding with URL parameters to mode=Step3."
  post_args=(
    --get
    --data-urlencode "module=Install"
    --data-urlencode "view=Index"
    --data-urlencode "mode=Step3"
  )
```

---

## 🧪 Testing Protocol

### Test 1: Local Build (Requires Docker & Docker Compose)

```bash
cd /path/to/vtiger-docker-main
IMAGE=vtigercrm-test VERSION=8.3.0-step2-fix ./build.sh --no-push
```

**Success criteria:**
- Docker build completes without errors
- Builder stage runs `install.sh`
- Logs show: `Step2 is a license agreement (GET form, no data submission).`
- Logs show: `Step2 (GET request)` in payload fields
- Mode advances: `Step2` → `Step3` (visible in logs)
- Database schema created (mysqldump succeeds)
- Runtime image built successfully

**Log markers to find:**

```
[vtiger-install] Step2 is a license agreement (GET form, no data submission).
[vtiger-install] Form method=get; proceeding with URL parameters to mode=Step3.
[vtiger-install] Step2 (GET request) payload fields (3):
[vtiger-install]   - module=<set>
[vtiger-install]   - view=<set>
[vtiger-install]   - mode=<set>
[vtiger-install] Installer submit HTTP response code: 200
[vtiger-install] Installer visible step after submit: Requirements
[vtiger-install] Installer mode marker after submit: Step3
```

### Test 2: Smoke Test (Requires Docker Compose)

```bash
docker compose up -d
# Wait 60 seconds for initialization
sleep 60

# Login test
curl -s -b cookies.txt -c cookies.txt \
  -F 'user_name=admin' \
  -F 'user_password=Admin@1234' \
  http://localhost:8080/index.php \
  | grep -i 'dashboard\|modules\|vtiger' && echo "✅ Login successful"
```

**Success criteria:**
- Container starts without errors
- Apache listens on port 80
- Database initializes from schema.sql
- Application responds to HTTP requests
- Admin login works with default credentials

```bash
docker compose down -v
```

### Test 3: Manual Debugging (If Build Fails)

#### A. Inspect HTML Artifacts

```bash
# Inside the builder container or after build:
ls -la /tmp/vtiger-install-step-*.html

# View Step2 HTML
cat /tmp/vtiger-install-step-1-post.html | grep -A 5 '<form'

# Verify mode marker
grep 'name="mode"' /tmp/vtiger-install-step-1-post.html
# Should show: <input type=hidden name="mode" value="Step3" />
```

#### B. Check curl Behavior

```bash
# Simulate Step2 GET request
curl -v -G \
  --data-urlencode "module=Install" \
  --data-urlencode "view=Index" \
  --data-urlencode "mode=Step3" \
  http://localhost:8181/index.php 2>&1 | grep -E '^>|^<'

# Expected: GET /index.php?module=Install&view=Index&mode=Step3
```

#### C. Database Verification

```bash
# Inside container or MySQL client:
mysql -h mysql -u vtiger -pvtigerpass -D vtiger

# Check for schema tables:
SHOW TABLES LIKE 'vtiger_%' LIMIT 10;

# Count tables (should be > 100):
SELECT COUNT(*) FROM information_schema.tables 
WHERE table_schema='vtiger' AND table_name LIKE 'vtiger_%';
```

---

## 📊 Expected Log Flow

### Before Fix (BROKEN)
```
[vtiger-install] Loading installer entry page: http://127.0.0.1:8181/index.php?module=Install&view=Index
[vtiger-install] Installer entry HTTP response code: 200
[vtiger-install] Installer visible step: Welcome
[vtiger-install] Installer mode marker: Step1

[vtiger-install] Submitting installer step 1 to http://127.0.0.1:8181/index.php (site_URL=http://localhost:8080)...
[vtiger-install] Step1 payload fields (5):
[vtiger-install]   - module=<set>
[vtiger-install]   - view=<set>
[vtiger-install]   - mode=<set>
[vtiger-install]   - default_language=<set>
[vtiger-install]   - accept_license=<set>
[vtiger-install] Installer submit HTTP response code: 200
[vtiger-install] Installer visible step after submit: Welcome
[vtiger-install] Installer mode marker after submit: Step2

[vtiger-install] Submitting installer step 2 to http://127.0.0.1:8181/index.php (site_URL=http://localhost:8080)...
[vtiger-install] Step2 payload fields (3):
[vtiger-install]   - module=<set>
[vtiger-install]   - view=<set>
[vtiger-install]   - mode=<set>
[vtiger-install] Installer submit HTTP response code: 200
[vtiger-install] Installer visible step after submit: Welcome
[vtiger-install] Installer mode marker after submit: Step2
[vtiger-install] ERROR: Installer made no progress: still on step 'Welcome' (mode 'Step2') after POST 2.
```

### After Fix (WORKING)
```
[vtiger-install] Loading installer entry page: http://127.0.0.1:8181/index.php?module=Install&view=Index
[vtiger-install] Installer entry HTTP response code: 200
[vtiger-install] Installer visible step: Welcome
[vtiger-install] Installer mode marker: Step1

[vtiger-install] Submitting installer step 1 to http://127.0.0.1:8181/index.php (site_URL=http://localhost:8080)...
[vtiger-install] Step1 payload fields (5):
[vtiger-install]   - module=<set>
[vtiger-install]   - view=<set>
[vtiger-install]   - mode=<set>
[vtiger-install]   - default_language=<set>
[vtiger-install]   - accept_license=<set>
[vtiger-install] Installer submit HTTP response code: 200
[vtiger-install] Installer visible step after submit: Welcome
[vtiger-install] Installer mode marker after submit: Step2

[vtiger-install] Step2 is a license agreement (GET form, no data submission).
[vtiger-install] Form method=get; proceeding with URL parameters to mode=Step3.
[vtiger-install] Step2 (GET request) payload fields (3):
[vtiger-install]   - module=<set>
[vtiger-install]   - view=<set>
[vtiger-install]   - mode=<set>
[vtiger-install] Installer submit HTTP response code: 200
[vtiger-install] Installer visible step after submit: Requirements
[vtiger-install] Installer mode marker after submit: Step3

[vtiger-install] Submitting installer step 3 to http://127.0.0.1:8181/index.php (site_URL=http://localhost:8080)...
[vtiger-install] Step3 payload fields (1):
[vtiger-install]   - mode=<set>
[vtiger-install] Installer submit HTTP response code: 200
[vtiger-install] Installer visible step after submit: Pre-Installation
[vtiger-install] Installer mode marker after submit: Step3
...continues to Step4, Step5, Step6, Step7...
```

---

## 🔍 Troubleshooting

### Issue: "Still stuck on Step2"

**Check 1: Verify the patch was applied**
```bash
grep -n "GET form, no data submission" init-scripts/install.sh
# Should show a line number > 0
```

**Check 2: Verify curl is using GET**
```bash
# Add this after post_args=() in Step2 block:
log "DEBUG: post_args = '${post_args[*]}'"

# Should show: post_args = --get --data-urlencode module=Install ...
```

**Check 3: Check HTML form method**
```bash
cat /tmp/vtiger-install-step-1-post.html | grep -A 1 '<form'
# Should show: <form class="form-horizontal" name="step2" method="get"
```

**Check 4: Verify response contains mode=Step3**
```bash
cat /tmp/vtiger-install-step-2-post.html | grep 'name="mode"'
# Should show: <input type=hidden name="mode" value="Step3"
```

### Issue: "HTTP 200 but mode marker still Step2"

**Likely cause:** Form extraction failed or HTML changed.

```bash
# Extract the mode manually
perl -0777 -ne 'if (/<input\b[^>]*name="mode"[^>]*value="([^"]+)"/i) { print $1 }' \
  /tmp/vtiger-install-step-2-post.html
# Should output: Step3
```

### Issue: "Curl command syntax error"

**Verify curl version:**
```bash
curl --version | head -1
# Should be 7.65+
```

**Test --get with --data-urlencode:**
```bash
curl --get --data-urlencode "test=hello world" \
  -o /dev/null -w '%{url_effective}\n' \
  http://httpbin.org/get
# Should output: http://httpbin.org/get?test=hello+world
```

### Issue: "Step3 reached but Step4 fails"

**Step2 fix is working!** Failure at Step4+ is a different issue. Check:
- Database connection parameters (Step4/Step5)
- Schema initialization (Step6/Step7)
- Permissions on `/app/logs`, `/app/cache` directories

---

## 📋 Checklist Before Deploying

- [ ] Patch applied cleanly (`patch -p0 < step2.patch`)
- [ ] No merge conflicts in `init-scripts/install.sh`
- [ ] Grep confirms `--get` flag is present
- [ ] Docker build runs to completion
- [ ] Logs show Step2 → Step3 transition
- [ ] Mode marker changes: `Step2` → `Step3` ✅
- [ ] No "made no progress" error ✅
- [ ] Schema created (mysqldump succeeds)
- [ ] Runtime image builds
- [ ] Smoke test: login works
- [ ] No regression: Steps 3-7 still work

---

## 🚀 Deployment Steps

### 1. Update Repository

```bash
cd /path/to/vtiger-docker-main

# Option A: Apply patch
patch -p0 < step2.patch

# Option B: Manual update
# Edit init-scripts/install.sh lines 628-647 as shown in step2.patch
```

### 2. Rebuild Image

```bash
# Full build (recommended for CI/CD)
./build.sh --no-push

# Or just builder stage for quick testing
docker compose -f docker-compose.build.yml build installer
```

### 3. Verify Build Success

```bash
# Check build logs for Step2 messages
docker build -f Dockerfile --target=builder . 2>&1 | grep -i "step2\|step3"

# Should show:
# Step2 is a license agreement
# Form method=get
# Step3 payload fields
```

### 4. Publish (if using CI/CD)

```bash
# Tag and push
docker tag vtigercrm:8.3.0 ghcr.io/bighog300/vtigercrm:8.3.0
docker push ghcr.io/bighog300/vtigercrm:8.3.0
```

### 5. Test in Staging

```bash
# Pull and run
docker pull ghcr.io/bighog300/vtigercrm:8.3.0
docker compose up -d

# Wait for startup
sleep 60

# Test login
curl -s -b cookies.txt -c cookies.txt \
  -F 'user_name=admin' \
  -F 'user_password=Admin@1234' \
  http://localhost:8080/index.php | grep -q 'dashboard' && echo "✅"
```

---

## 📞 Support

### If the fix still doesn't work:

1. **Collect diagnostics:**
   ```bash
   # Save all installer HTML artifacts
   tar czf /tmp/vtiger-install-artifacts.tar.gz /tmp/vtiger-install-*.html
   
   # Save full build log
   docker build -f Dockerfile --target=builder . 2>&1 | tee /tmp/build.log
   ```

2. **Check vtiger version:**
   ```bash
   grep -r "define.*vtiger_version\|VERSION\|version" /path/to/vtigercrm | head -5
   ```

3. **Verify form structure hasn't changed:**
   ```bash
   grep -A 10 'class="form-horizontal" name="step2"' layouts/vlayout/modules/Install/Step2.tpl
   ```

4. **Inspect network traffic (advanced):**
   ```bash
   # Run Apache inside container with tcpdump
   docker exec <container> tcpdump -A -n 'port 8181' 2>&1 | grep -A 5 'module=Install'
   ```

---

## 🎓 What This Fix Teaches

**Problem:** Form method mismatch (GET vs POST)
**Solution:** Match the HTTP method to the form's declared method
**Pattern:** Always inspect the form's `method` attribute before building POST/GET logic

This is foundational web automation:
- `<form method="post">` → use curl POST (default)
- `<form method="get">` → use curl GET (`--get` flag)
- Form `action` → becomes the URL
- Hidden inputs → become parameters
- `<input type="submit" name="btn" value="Click">` → becomes `&btn=Click` in POST or `?btn=Click` in GET

For vtiger installer:
- Steps 1, 3-7: POST forms (modify state, save to session)
- Step 2: GET form (read-only, navigate via pre-declared mode)

---

## ✅ Acceptance Criteria (Final)

After applying and testing:

✅ **Functional**
- [ ] Step2 POST request uses GET (--get flag visible in logs)
- [ ] Mode advances from Step2 to Step3
- [ ] No "made no progress" error
- [ ] Installer continues to Step3+ without stalling

✅ **Quality**
- [ ] No new errors or warnings introduced
- [ ] Logs are clear and diagnostic
- [ ] No changes to other steps (Steps 1, 3-7 unaffected)
- [ ] Backward compatible (no breaking changes)

✅ **Deployment**
- [ ] Patch applies cleanly
- [ ] Build succeeds
- [ ] Image runs and passes smoke test
- [ ] Documentation is clear for future maintainers

