const page = new Page();
await page.goto("https://news.ycombinator.com/login");
page.waitForSelector("input[name=\"acct\"]");
page.fill("input[name=\"acct\"]", "$LP_HN_USERNAME");
page.fill("input[name=\"pw\"]", "$LP_HN_PASSWORD");
page.press("input[name=\"pw\"]", "Enter");
await page.goto("https://news.ycombinator.com/user?id=$LP_HN_USERNAME");
const { karma } = page.extract({ karma: "#hnmain table table tr:nth-child(3) td:nth-child(2)" });
return { karma: parseInt(karma, 10) };
