# Visual Comparison: Step2 Problem & Solution

## 🔴 BROKEN: Using POST (Previous Behavior)

```
┌─────────────────────────────────────────────────────────────────┐
│ Browser/Curl Request (WRONG)                                    │
└─────────────────────────────────────────────────────────────────┘

POST /index.php HTTP/1.1
Host: localhost:8181
Content-Type: application/x-www-form-urlencoded

module=Install&view=Index&mode=Step3

        ↓
        
┌─────────────────────────────────────────────────────────────────┐
│ Server: Install_Index_view Controller                           │
└─────────────────────────────────────────────────────────────────┘

$mode = $request->getMode();  // Reads POST/GET params
// mode = "Step3"
// BUT the form method was GET, so mode stays as Step2 in the
// response HTML because the handler thinks this is a regular POST

        ↓
        
┌─────────────────────────────────────────────────────────────────┐
│ Response HTML (STILL STEP2)                                     │
└─────────────────────────────────────────────────────────────────┘

<form method="get" action="index.php">
  <input type=hidden name="module" value="Install" />
  <input type=hidden name="view" value="Index" />
  <input type=hidden name="mode" value="Step2" />  ← STILL STEP2!
</form>

        ↓
        
┌─────────────────────────────────────────────────────────────────┐
│ Installer Loop: Progress Check FAILS                            │
└─────────────────────────────────────────────────────────────────┘

before:  mode = "Step2"
after:   mode = "Step2"
result:  ❌ "Installer made no progress"
exit:    ERROR (no progression)

┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃                                                                 ┃
┃  ROOT CAUSE: Script sent POST, but form expects GET            ┃
┃  Result: Step2 re-rendered, mode field unchanged               ┃
┃                                                                 ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
```

---

## 🟢 FIXED: Using GET (New Behavior)

```
┌─────────────────────────────────────────────────────────────────┐
│ Browser/Curl Request (CORRECT)                                  │
└─────────────────────────────────────────────────────────────────┘

GET /index.php?module=Install&view=Index&mode=Step3 HTTP/1.1
Host: localhost:8181

(no body, GET parameters in URL)

        ↓
        
┌─────────────────────────────────────────────────────────────────┐
│ Server: Install_Index_view Controller                           │
└─────────────────────────────────────────────────────────────────┘

$mode = $request->getMode();  // Reads GET params
// mode = "Step3"
// Form method=get, so this is expected
// Controller calls Step3() handler

public function Step3(Vtiger_Request $request) {
    $viewer->view('Step3.tpl', $moduleName);  // Render Step3
}

        ↓
        
┌─────────────────────────────────────────────────────────────────┐
│ Response HTML (NOW STEP3)                                       │
└─────────────────────────────────────────────────────────────────┘

<form method="post" action="index.php">
  <input type=hidden name="module" value="Install" />
  <input type=hidden name="view" value="Index" />
  <input type=hidden name="mode" value="Step3" />  ← NOW STEP3!
  ... Step3 form fields (Requirements check) ...
</form>

        ↓
        
┌─────────────────────────────────────────────────────────────────┐
│ Installer Loop: Progress Check SUCCEEDS                         │
└─────────────────────────────────────────────────────────────────┘

before:  mode = "Step2"
after:   mode = "Step3"
result:  ✅ Progress detected
next:    Loop continues to Step4 (and beyond)

┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃                                                                 ┃
┃  FIX: Script sends GET, form expects GET ✅                   ┃
┃  Result: Step3 rendered, mode advances, installer progresses   ┃
┃                                                                 ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
```

---

## 📊 Curl Command Comparison

### ❌ BROKEN: POST Method

```bash
curl -sS \
  -c cookies.txt -b cookies.txt \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "module=Install" \
  --data-urlencode "view=Index" \
  --data-urlencode "mode=Step3" \
  http://127.0.0.1:8181/index.php

# Result: POST request with body
# POST /index.php HTTP/1.1
# Content-Length: 51
#
# module=Install&view=Index&mode=Step3
#
# ❌ Server re-renders Step2 (form.method=get not matched)
```

### ✅ FIXED: GET Method

```bash
curl -sS \
  -c cookies.txt -b cookies.txt \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --get \
  --data-urlencode "module=Install" \
  --data-urlencode "view=Index" \
  --data-urlencode "mode=Step3" \
  http://127.0.0.1:8181/index.php

# Result: GET request with URL params
# GET /index.php?module=Install&view=Index&mode=Step3 HTTP/1.1
#
# ✅ Server renders Step3 (form.method=get matched)
```

---

## 📝 HTML Form Structure (Step2 vs Step3)

### Step2: GET Form (Simple, No Data Submission)

```html
<form class="form-horizontal" name="step2" method="get" action="index.php">
  <input type=hidden name="module" value="Install" />
  <input type=hidden name="view" value="Index" />
  <input type=hidden name="mode" value="Step3" />
  
  <!-- Large license text (read-only) -->
  <div class="license">
    <div class="lic-scroll">
      PLEASE READ THE FOLLOWING LICENSE AGREEMENT...
    </div>
  </div>
  
  <!-- Only two buttons, no name/value pairs -->
  <div class="button-container">
    <input name="back" type="button" class="btn" value="Disagree"/>
    <input id="agree" type="submit" class="btn btn-primary" value="I Agree"/>
    <!-- ↑ No name attribute, so doesn't get sent in URL -->
  </div>
</form>

<!-- Key insight: mode=Step3 is PRE-DECLARED by the form itself -->
<!-- When user clicks "I Agree", the form navigates to mode=Step3 -->
<!-- No form data validation needed (it's just an acknowledgment) -->
```

### Step3: POST Form (Complex, Data Submission)

```html
<form class="form-horizontal" name="step3" method="post" action="index.php">
  <input type=hidden name="module" value="Install" />
  <input type=hidden name="view" value="Index" />
  <input type=hidden name="mode" value="Step3" />
  
  <!-- System requirements check (read-only display) -->
  <table class="requirements">
    <tr>
      <td>PHP Version</td>
      <td>8.3.0</td>
      <td class="pass">✓</td>
    </tr>
    <!-- More checks... -->
  </table>
  
  <!-- Hidden field to advance (calculated server-side) -->
  <input type=hidden name="next_mode" value="Step4" />
  
  <div class="button-container">
    <input name="back" type="button" value="Back"/>
    <input name="next" type="submit" value="Next"/>
    <!-- ↑ Submit button name will be sent as "next=Next" in POST -->
  </div>
</form>

<!-- Key insight: mode=Step3 indicates current state -->
<!-- Server calculates next_mode after validation -->
<!-- Form submission is data-driven (POST method) -->
```

---

## 🔄 Installer Flow Diagram

```
┌──────────────┐
│   Step1      │  Welcome: Choose language
│   (POST)     │  Form: method="post"
└──────┬───────┘  Mode: Step1 → Step2 (button click)
       │
       ↓
┌──────────────┐
│   Step2      │  License Agreement
│   (GET)      │  Form: method="get"  ← THE FIX IS HERE
└──────┬───────┘  Mode: Step2 → Step3 (hardcoded in hidden field)
       │          *** Uses GET, not POST ***
       ↓
┌──────────────┐
│   Step3      │  Requirements Check
│   (POST)     │  Form: method="post"
└──────┬───────┘  Mode: Step3 → Step4 (button click)
       │
       ↓
┌──────────────┐
│   Step4      │  Database Config
│   (POST)     │  Form: method="post"
└──────┬───────┘  Mode: Step4 → Step5 (button click)
       │
       ↓
┌──────────────┐
│   Step5      │  Company Details
│   (POST)     │  Form: method="post"
└──────┬───────┘  Mode: Step5 → Step6 (button click)
       │
       ↓
┌──────────────┐
│   Step6      │  Confirmation
│   (POST)     │  Form: method="post"
└──────┬───────┘  Mode: Step6 → Step7 (button click)
       │
       ↓
┌──────────────┐
│   Step7      │  Installation (DB schema, modules)
│   (POST)     │  Form: method="post"
└──────┬───────┘  Mode: Step7 → Completed
       │
       ↓
   ✅ SUCCESS
   Database initialized
   Application ready

Legend:
  (POST) = uses POST method, form data submission
  (GET)  = uses GET method, URL parameters only
```

---

## 🔍 Why This Matters: HTTP Semantics

### HTTP GET

```
RFC 7231: "GET method requests a representation of the specified resource"
Semantics: Safe, Idempotent, Read-only
Use case: Navigate, acknowledge, retrieve data
Body: None (parameters in URL)
Side effects: None (server shouldn't modify state)
Caching: Responses are cacheable
Bookmarkable: Yes
Max URL length: ~2000 chars (varies by server)
```

### HTTP POST

```
RFC 7231: "POST method requests that the target resource process the
           representation enclosed in the request according to the resource's own semantics"
Semantics: Not necessarily safe, Not idempotent, Modify state
Use case: Submit form data, create/update resources, trigger actions
Body: Yes (form data, JSON, etc.)
Side effects: May modify server state
Caching: Must handle carefully
Bookmarkable: No
Max data: Unlimited (server-dependent)
```

### Step2 Analysis

- **Action:** User acknowledges they've read the license
- **State change:** None (just navigation)
- **Data:** None (no form fields with data)
- **Idempotent:** Yes (clicking "I Agree" 10x = same result)
- **Semantic HTTP method:** GET ✅

### Steps 3-7 Analysis

- **Action:** Submit configuration data, run installation
- **State change:** Yes (session saves parameters, DB modified)
- **Data:** Yes (DB host, admin password, etc.)
- **Idempotent:** No (each submission progresses the installation)
- **Semantic HTTP method:** POST ✅

---

## 📈 Error Propagation

### What Happens When Methods Don't Match

```
Script behavior: POST
Form expectation: GET

When script sends POST to a GET form:
├─ Server receives POST request ✓ (HTTP OK)
├─ Query string is parsed ✓ (parameters extracted)
├─ Mode parameter is read ✓ (mode=Step3)
├─ Step3 handler is called ✓
├─ BUT the form is re-rendered with @LOCATION hints
│  that indicate "this form should be GET, not POST"
├─ Response HTML still shows mode=Step2 (initial step)
│  because the template logic expects GET-based navigation
└─ Browser/curl sees: "Mode is still Step2"
   → Installer progress check fails
   → Loop breaks with error
```

### What Happens When Methods Match (Fixed)

```
Script behavior: GET
Form expectation: GET

When script sends GET to a GET form:
├─ Server receives GET request ✓ (HTTP OK)
├─ Query string is parsed ✓ (parameters extracted)
├─ Mode parameter is read ✓ (mode=Step3)
├─ Step3 handler is called ✓
├─ Response HTML shows mode=Step3 (current step)
│  because the template logic works as designed
├─ Browser/curl sees: "Mode is now Step3"
└─ Installer progress check passes
   → Loop continues
   → Installer progresses
```

---

## 💡 Key Takeaways

1. **Always inspect the HTML form's `method` attribute**
   - `<form method="post">` → use curl POST
   - `<form method="get">` → use curl GET

2. **Match HTTP method to semantic intent**
   - Read-only navigation → GET (idempotent)
   - Data submission → POST (may cause side effects)

3. **Use curl correctly**
   - POST (default): `curl --data "key=value" URL`
   - GET: `curl --get --data-urlencode "key=value" URL`

4. **Test the actual form submission**
   - Don't assume all forms in a workflow use the same method
   - Each step may be different (as vtiger demonstrates)

5. **Read error messages carefully**
   - "No progress" → check mode markers in response
   - Check HTML source for form method, hidden fields, buttons
   - Use curl `-v` flag to see actual HTTP requests/responses

---

## 🎯 Before and After Summary

| Aspect | Before (Broken) | After (Fixed) |
|--------|-----------------|---------------|
| HTTP Method | POST | GET |
| Curl Flag | (none, defaults to POST) | `--get` |
| Request Body | Form data (module, view, mode) | None (empty) |
| URL | `/index.php` | `/index.php?module=Install&view=Index&mode=Step3` |
| Mode Marker Response | Step2 (unchanged) | Step3 (progressed) |
| Installer Progress | ❌ Failed | ✅ Succeeded |
| Error | "made no progress" | (none, continues) |
| Next Step | N/A (stuck) | Step4 (Requirements) |

