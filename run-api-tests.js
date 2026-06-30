/**
 * Newman runner for admin-service API tests.
 *
 * Usage:
 *   npm install --save-dev newman          (first time only)
 *   node run-api-tests.js                  (uses defaults from .env / collection)
 *   node run-api-tests.js http://localhost:5001 admin yourpassword
 *
 * Output:  test-results-<timestamp>.log
 */

const newman = require('newman');
const fs     = require('fs');
const path   = require('path');

const BASE_URL       = process.argv[2] || 'http://localhost:5001';
const ADMIN_USERNAME = process.argv[3] || 'admin';
const ADMIN_PASSWORD = process.argv[4] || process.env.ADMIN_PASSWORD || 'YOUR_ADMIN_PASSWORD_HERE';

const COLLECTION_FILE  = path.join(__dirname, 'admin-service.postman_collection.json');
const TIMESTAMP        = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
const LOG_FILE         = path.join(__dirname, `test-results-${TIMESTAMP}.log`);

// ─── Log builder ────────────────────────────────────────────────────────────

const lines = [];
const log   = (...args) => lines.push(args.join(' '));

// ─── Tracking state ─────────────────────────────────────────────────────────

let totalRequests = 0;
let totalTests    = 0;
let passedTests   = 0;
const failedItems = [];

// ─── Run ────────────────────────────────────────────────────────────────────

console.log(`\nAdmin Service API Tests`);
console.log(`Base URL  : ${BASE_URL}`);
console.log(`Log file  : ${LOG_FILE}`);
console.log(`Running...`);

newman.run(
  {
    collection: require(COLLECTION_FILE),
    envVar: [
      { key: 'baseUrl',        value: BASE_URL       },
      { key: 'adminUsername',  value: ADMIN_USERNAME },
      { key: 'adminPassword',  value: ADMIN_PASSWORD }
    ],
    reporters: ['cli'],
    reporter:  { cli: { silent: false } },
    delayRequest: 100
  },

  function (err, summary) {
    if (err) {
      console.error('Newman run error:', err.message);
      process.exit(1);
    }

    const run      = summary.run;
    const duration = ((run.timings.completed - run.timings.started) / 1000).toFixed(2);

    // ── Header ──────────────────────────────────────────────────────────────
    log('='.repeat(60));
    log('  ADMIN SERVICE — API TEST RESULTS');
    log('='.repeat(60));
    log(`  Date     : ${new Date().toUTCString()}`);
    log(`  Base URL : ${BASE_URL}`);
    log(`  Duration : ${duration}s`);
    log('='.repeat(60));
    log('');

    // ── Summary ─────────────────────────────────────────────────────────────
    const stats = run.stats;
    totalRequests = stats.requests.total;
    totalTests    = stats.assertions.total;
    passedTests   = stats.assertions.total - stats.assertions.failed;

    log('SUMMARY');
    log('-'.repeat(40));
    log(`  Requests : ${totalRequests}`);
    log(`  Tests    : ${totalTests}`);
    log(`  Passed   : ${passedTests}`);
    log(`  Failed   : ${stats.assertions.failed}`);
    log(`  Pass Rate: ${totalTests > 0 ? ((passedTests / totalTests) * 100).toFixed(1) : 0}%`);
    log('');

    // ── Per-request detail ───────────────────────────────────────────────────
    log('='.repeat(60));
    log('DETAILS');
    log('='.repeat(60));
    log('');

    let currentFolder = null;

    run.executions.forEach(exec => {
      const item   = exec.item;
      const folder = item.parent && item.parent().name !== summary.collection.name
        ? item.parent().name
        : null;

      if (folder && folder !== currentFolder) {
        currentFolder = folder;
        log(`[ ${folder.toUpperCase()} ]`);
        log('');
      }

      const method   = exec.request.method;
      const urlRaw   = exec.request.url ? exec.request.url.toString() : '(no url)';
      const urlPath  = urlRaw.replace(BASE_URL, '');
      const status   = exec.response ? exec.response.code : 'ERR';
      const ms       = exec.response ? exec.response.responseTime : '-';
      const reqFails = exec.assertions ? exec.assertions.filter(a => a.error) : [];
      const reqPass  = exec.assertions ? exec.assertions.filter(a => !a.error) : [];
      const allPass  = reqFails.length === 0;
      const icon     = allPass ? '✓' : '✗';

      log(`  ${icon} ${method.padEnd(6)} ${item.name}`);
      log(`      ${urlPath}`);
      log(`      Status  : ${status}   (${ms}ms)`);

      reqPass.forEach(a  => log(`      ✓ ${a.assertion}`));
      reqFails.forEach(a => {
        log(`      ✗ ${a.assertion}`);
        log(`        Error : ${a.error && a.error.message ? a.error.message : 'assertion failed'}`);
        failedItems.push({
          request:   `${method} ${urlPath}`,
          test:      a.assertion,
          error:     a.error && a.error.message ? a.error.message : 'assertion failed',
          status
        });
      });

      if (exec.requestError) {
        log(`      ✗ REQUEST ERROR: ${exec.requestError.message}`);
        failedItems.push({
          request: `${method} ${urlPath}`,
          test:    'Request error',
          error:   exec.requestError.message,
          status:  'ERR'
        });
      }

      log('');
    });

    // ── Failed summary ───────────────────────────────────────────────────────
    log('='.repeat(60));
    if (failedItems.length === 0) {
      log('FAILED TESTS');
      log('-'.repeat(40));
      log('  None — all tests passed!');
    } else {
      log(`FAILED TESTS  (${failedItems.length})`);
      log('-'.repeat(40));
      failedItems.forEach((f, i) => {
        log(`  ${i + 1}. ${f.request}`);
        log(`     Test   : ${f.test}`);
        log(`     Error  : ${f.error}`);
        log(`     Status : ${f.status}`);
        log('');
      });
    }
    log('='.repeat(60));

    // ── Write log file ──────────────────────────────────────────────────────
    fs.writeFileSync(LOG_FILE, lines.join('\n'), 'utf8');
    console.log(`\nLog written → ${LOG_FILE}`);

    if (stats.assertions.failed > 0) {
      console.log(`\n${stats.assertions.failed} test(s) failed. See log for details.`);
      process.exit(1);
    } else {
      console.log(`\nAll ${totalTests} tests passed.`);
    }
  }
);
