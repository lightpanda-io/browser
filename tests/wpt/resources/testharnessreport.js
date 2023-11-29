/*
 * Prepare a report object containeing all tests results.
 * https://wpt-docs.readthedocs.io/en/latest/_writing-tests/testharness-api.html#callback-api
 */
var report = {
  status: "",
  log: "",
};

add_completion_callback(function (tests, status) {
  // report the tests global status.
  // TODO the status.status is always OK even if a test fail.
  // I ignore the global status for now, but I build one with the tests results.
  //report.status = status.status;

  var status = "Pass";
  // report a log with details per test.
  var log = "";
  for (var i = 0; i < tests.length; i++) {
    const test = tests[i];
    log += test.name+"|"+test.format_status();
    if (test.message != null) {
      log +=  "|"+test.message.replaceAll("\n"," ");
    }
    log += "\n";

    if (test.status !== 0) {
      status = test.format_status();
    }
  }

  report.log = log;
  report.status = status;
});
