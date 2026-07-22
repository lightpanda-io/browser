const page = new Page();
await page.goto("https://news.ycombinator.com");

const { stories } = page.extract({
  stories: [{
    selector: "tr.athing",
    limit: 5,
    fields: {
      id: { selector: "", attr: "id" },
      rank: ".rank",
      title: ".titleline > a"
    }
  }]
});

const { scoreSpans } = page.extract({
  scoreSpans: [{
    selector: ".score",
    fields: {
      id: { selector: "", attr: "id" },
      points: ""
    }
  }]
});

const { authors } = page.extract({
  authors: [".hnuser"]
});

// .score id is "score_<storyId>"; .hnuser entries are parallel to .score entries
const scoreMap = {};
const authorMap = {};
scoreSpans.forEach((s, i) => {
  const storyId = s.id.replace("score_", "");
  scoreMap[storyId] = s.points;
  authorMap[storyId] = authors[i] || null;
});

const results = stories.map(s => ({
  rank: s.rank.replace(".", "").trim(),
  title: s.title,
  author: authorMap[s.id] || null,
  score: scoreMap[s.id] || null
}));

return results;
