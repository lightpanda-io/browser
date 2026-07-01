// Deterministic golden script: top 5 stories from the frozen HN front-page
// fixture, then the top 3 comments of each story's frozen item page.
// Navigates to the local fixture server instead of news.ycombinator.com, so
// replay is fully reproducible with no LLM and no network. Keep in sync with
// golden/hn-front.json; the port is pinned by run.sh.
const BASE = "http://127.0.0.1:8081/hn";

const page = new Page();
await page.goto(`${BASE}/front.html`);

const { stories } = page.extract({
  stories: [{
    selector: ".athing",
    limit: 5,
    fields: {
      rank: ".rank",
      title: ".titleline > a",
      url: { selector: ".titleline > a", attr: "href" },
      id: { selector: "", attr: "id" }
    }
  }]
});

const results = [];

for (const story of stories) {
  await page.goto(`${BASE}/item-${story.id}.html`);
  const { comments } = page.extract({
    comments: [{
      selector: ".comtr",
      limit: 3,
      fields: {
        user: ".hnuser",
        text: ".commtext"
      }
    }]
  });
  results.push({
    rank: story.rank,
    title: story.title,
    url: story.url,
    comments
  });
}

return results;
