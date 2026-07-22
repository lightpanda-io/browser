// Navigate to Hacker News homepage
const mainPage = new Page();
await mainPage.goto("https://news.ycombinator.com/");

// Extract the top 5 stories and their unique item IDs
const { stories } = mainPage.extract({
  stories: [{
    selector: "tr.athing",
    limit: 5,
    fields: {
      id: { selector: "", attr: "id" },
      title: ".titleline > a",
      link: { selector: ".titleline > a", attr: "href" }
    }
  }]
});

// Create parallel page instances for each of the top 5 stories
const commentPages = stories.map(() => new Page());

// Navigate to all 5 comment pages concurrently
await Promise.all(commentPages.map((p, i) => p.goto(`https://news.ycombinator.com/item?id=${stories[i].id}`)));

// Extract the top 3 comments from each story's comment page
const results = commentPages.map((p, i) => {
  const { comments } = p.extract({
    comments: [{
      selector: "tr.comtr",
      limit: 3,
      fields: {
        author: "a.hnuser",
        text: ".commtext"
      }
    }]
  });
  return {
    title: stories[i].title,
    link: stories[i].link,
    comments: comments
  };
});

// Return the aggregated list of stories with their comments
return results;
