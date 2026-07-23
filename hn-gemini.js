const mainPage = new Page();
await mainPage.goto("https://news.ycombinator.com");

const { stories } = mainPage.extract({
  stories: [
    {
      selector: ".athing",
      limit: 5,
      fields: {
        id: { selector: "", attr: "id" },
        title: ".titleline > a",
        url: { selector: ".titleline > a", attr: "href" },
      },
    },
  ],
});

const detailPages = stories.map(() => new Page());
await Promise.all(
  detailPages.map((p, i) =>
    p.goto(`https://news.ycombinator.com/item?id=${stories[i].id}`),
  ),
);

const results = stories.map((story, i) => {
  const p = detailPages[i];
  const { comments } = p.extract({
    comments: [
      {
        selector: ".comtr",
        limit: 3,
        fields: {
          user: ".hnuser",
          text: ".commtext",
        },
      },
    ],
  });
  return {
    title: story.title,
    url: story.url,
    comments: comments,
  };
});

return results;
