## role

● Here's a comprehensive list of implicit ARIA roles for HTML elements:

  Complete HTML Element → Implicit ARIA Role Mapping

  Navigation & Structure

  | Element   | Implicit Role | Conditions                                                  |
  |-----------|---------------|-------------------------------------------------------------|
  | <nav>     | navigation    | Always                                                      |
  | <main>    | main          | Always                                                      |
  | <aside>   | complementary | Always                                                      |
  | <header>  | banner        | Not descendant of article, aside, main, nav, section        |
  | <header>  | (none)        | When descendant of article, aside, main, nav, section       |
  | <footer>  | contentinfo   | Not descendant of article, aside, main, nav, section        |
  | <footer>  | (none)        | When descendant of article, aside, main, nav, section       |
  | <section> | region        | Has accessible name (aria-label, aria-labelledby, or title) |
  | <section> | (none)        | No accessible name                                          |
  | <article> | article       | Always                                                      |
  | <address> | group         | Always                                                      |

  Headings

  | Element  | Implicit Role | Notes          |
  |----------|---------------|----------------|
  | <h1>     | heading       | aria-level="1" |
  | <h2>     | heading       | aria-level="2" |
  | <h3>     | heading       | aria-level="3" |
  | <h4>     | heading       | aria-level="4" |
  | <h5>     | heading       | aria-level="5" |
  | <h6>     | heading       | aria-level="6" |
  | <hgroup> | group         | Always         |

  Lists

  | Element | Implicit Role | Conditions                |
  |---------|---------------|---------------------------|
  | <ul>    | list          | Always                    |
  | <ol>    | list          | Always                    |
  | <li>    | listitem      | Parent is ul, ol, or menu |
  | <dl>    | (none)        | Always                    |
  | <dt>    | term          | Always                    |
  | <dd>    | definition    | Always                    |
  | <menu>  | list          | Always                    |

  Forms & Inputs

  | Element                        | Implicit Role | Conditions                   |
  |--------------------------------|---------------|------------------------------|
  | <form>                         | form          | Has accessible name          |
  | <form>                         | (none)        | No accessible name           |
  | <input type="button">          | button        | Always                       |
  | <input type="checkbox">        | checkbox      | Always                       |
  | <input type="color">           | (none)        | No role                      |
  | <input type="date">            | (none)        | No standard role             |
  | <input type="datetime-local">  | (none)        | No standard role             |
  | <input type="email">           | textbox       | Always                       |
  | <input type="file">            | (none)        | No standard role             |
  | <input type="hidden">          | (none)        | Not exposed                  |
  | <input type="image">           | button        | Always                       |
  | <input type="month">           | (none)        | No standard role             |
  | <input type="number">          | spinbutton    | Always                       |
  | <input type="password">        | (none)        | No role (treated as textbox) |
  | <input type="radio">           | radio         | Always                       |
  | <input type="range">           | slider        | Always                       |
  | <input type="reset">           | button        | Always                       |
  | <input type="search">          | searchbox     | Always                       |
  | <input type="submit">          | button        | Always                       |
  | <input type="tel">             | textbox       | Always                       |
  | <input type="text">            | textbox       | Always                       |
  | <input type="time">            | (none)        | No standard role             |
  | <input type="url">             | textbox       | Always                       |
  | <input type="week">            | (none)        | No standard role             |
  | <input> (no type)              | textbox       | Default                      |
  | <textarea>                     | textbox       | Always                       |
  | <select> (no multiple, size≤1) | combobox      | Default                      |
  | <select multiple>              | listbox       | Always                       |
  | <select size="N"> (N>1)        | listbox       | When size > 1                |
  | <option>                       | option        | Always                       |
  | <optgroup>                     | group         | Always                       |
  | <button>                       | button        | Always                       |
  | <label>                        | (none)        | No role                      |
  | <fieldset>                     | group         | Always                       |
  | <legend>                       | (none)        | No role                      |
  | <output>                       | status        | Always                       |
  | <progress>                     | progressbar   | Always                       |
  | <meter>                        | meter         | Always                       |
  | <datalist>                     | listbox       | Always                       |

  Interactive Elements

  | Element   | Implicit Role | Conditions         |
  |-----------|---------------|--------------------|
  | <a>       | link          | Has href attribute |
  | <a>       | (none)        | No href attribute  |
  | <area>    | link          | Has href attribute |
  | <area>    | (none)        | No href attribute  |
  | <details> | group         | Always             |
  | <summary> | button        | Always             |
  | <dialog>  | dialog        | Always             |

  Media

  | Element      | Implicit Role | Conditions                             |
  |--------------|---------------|----------------------------------------|
  | <img>        | img           | Has non-empty alt attribute            |
  | <img>        | presentation  | Empty alt="" attribute                 |
  | <img>        | img           | No alt attribute (but should have one) |
  | <audio>      | (none)        | No standard role                       |
  | <video>      | (none)        | No standard role                       |
  | <figure>     | figure        | Always                                 |
  | <figcaption> | (none)        | No role                                |
  | <picture>    | (none)        | No role                                |

  Tables

  | Element    | Implicit Role | Conditions          |
  |------------|---------------|---------------------|
  | <table>    | table         | Always              |
  | <caption>  | caption       | Always              |
  | <thead>    | rowgroup      | Always              |
  | <tbody>    | rowgroup      | Always              |
  | <tfoot>    | rowgroup      | Always              |
  | <tr>       | row           | Always              |
  | <th>       | columnheader  | In context of table |
  | <th>       | rowheader     | scope="row"         |
  | <td>       | cell          | Always              |
  | <colgroup> | (none)        | No role             |
  | <col>      | (none)        | No role             |

  Text & Semantics

  | Element      | Implicit Role | Notes   |
  |--------------|---------------|---------|
  | <p>          | paragraph     | Always  |
  | <hr>         | separator     | Always  |
  | <pre>        | (none)        | No role |
  | <blockquote> | blockquote    | Always  |
  | <cite>       | (none)        | No role |
  | <code>       | code          | Always  |
  | <em>         | emphasis      | Always  |
  | <strong>     | strong        | Always  |
  | <mark>       | (none)        | No role |
  | <small>      | (none)        | No role |
  | <s>          | deletion      | Always  |
  | <del>        | deletion      | Always  |
  | <ins>        | insertion     | Always  |
  | <sub>        | subscript     | Always  |
  | <sup>        | superscript   | Always  |
  | <time>       | time          | Always  |
  | <abbr>       | (none)        | No role |
  | <dfn>        | term          | Always  |
  | <q>          | (none)        | No role |
  | <b>          | (none)        | No role |
  | <i>          | (none)        | No role |
  | <u>          | (none)        | No role |
  | <span>       | (none)        | No role |
  | <div>        | (none)        | No role |
  | <br>         | (none)        | No role |
  | <wbr>        | (none)        | No role |

  Document Structure

  | Element | Implicit Role | Notes       |
  |---------|---------------|-------------|
  | <html>  | document      | Always      |
  | <body>  | document      | Always      |
  | <head>  | (none)        | Not exposed |
  | <title> | (none)        | Not exposed |
  | <meta>  | (none)        | Not exposed |
  | <link>  | (none)        | Not exposed |
  | <style> | (none)        | Not exposed |
  | <base>  | (none)        | Not exposed |

  Embedded Content

  | Element  | Implicit Role     | Notes            |
  |----------|-------------------|------------------|
  | <iframe> | (none)            | No standard role |
  | <embed>  | (none)            | No standard role |
  | <object> | (none)            | No standard role |
  | <param>  | (none)            | Not exposed      |
  | <canvas> | (none)            | No role          |
  | <svg>    | graphics-document | Always           |
  | <math>   | math              | Always           |

  Scripting & Data

  | Element    | Implicit Role | Notes       |
  |------------|---------------|-------------|
  | <script>   | (none)        | Not exposed |
  | <noscript> | (none)        | Not exposed |
  | <template> | (none)        | Not exposed |
  | <slot>     | (none)        | Not exposed |
  | <data>     | (none)        | No role     |

  Deprecated/Obsolete Elements

  | Element    | Implicit Role | Notes    |
  |------------|---------------|----------|
  | <marquee>  | marquee       | Obsolete |
  | <blink>    | (none)        | Obsolete |
  | <frame>    | (none)        | Obsolete |
  | <frameset> | (none)        | Obsolete |

  Implementation Notes

  1. "(none)" means: Element has no implicit role, but is still exposed to accessibility tree
  2. "Not exposed" means: Element is not represented in accessibility tree at all
  3. Accessible name: Determined by aria-label, aria-labelledby, or title attribute
  4. Context-dependent roles: Some elements like <header>, <footer>, <th> have different roles based on their position in the DOM tree

  Priority Rules

  When computing role, follow this order:
  1. ✅ Explicit role attribute (if valid for that element)
  2. ✅ Implicit role from element type + attributes
  3. ✅ No role (generic element)


