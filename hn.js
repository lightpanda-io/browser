const page = new Page();
await page.goto("https://news.ycombinator.com");

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
  await page.goto(`https://news.ycombinator.com/item?id=${story.id}`);
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
