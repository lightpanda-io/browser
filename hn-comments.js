/*
 * Summary of Reasoning:
 * 1. Navigate to the Hacker News homepage to fetch the top 5 stories.
 * 2. Extract story details along with their item IDs to construct individual comment page URLs.
 * 3. Create independent Page objects for each story to load and extract their top 3 comments in parallel.
 * 4. Merge the extracted comments with their respective stories and return the compiled results.
 */

// Navigate to the Hacker News homepage
const homePage = new Page();
await homePage.goto("https://news.ycombinator.com");

// Extract the top 5 stories and their item IDs
const { stories } = homePage.extract({
  stories: [{
    selector: ".athing",
    limit: 5,
    fields: {
      id: { attr: "id" },
      title: ".titleline a",
      link: { selector: ".titleline a", attr: "href" }
    }
  }]
});

// Open comment pages for the top 5 stories in parallel
const commentPages = stories.map(() => new Page());
await Promise.all(
  commentPages.map((page, i) => page.goto(`https://news.ycombinator.com/item?id=${stories[i].id}`))
);

// Extract the top 3 comments from each story page and combine the results
const results = commentPages.map((page, i) => {
  const { comments } = page.extract({
    comments: [{
      selector: ".comment",
      limit: 3,
      fields: {
        text: ".commtext"
      }
    }]
  });

  return {
    title: stories[i].title,
    link: stories[i].link,
    discussionLink: `https://news.ycombinator.com/item?id=${stories[i].id}`,
    comments: comments.map(c => c.text ? c.text.trim() : "")
  };
});

return results;
