---
layout: page
title: Tags
permalink: /tags/
---

{%- assign tags = site.tags | sort -%}

<ul class="tag-list tag-index">
  {%- for tag in tags -%}
  <li><a class="tag" href="#{{ tag[0] | slugify }}">#{{ tag[0] }} <span class="tag-count">{{ tag[1].size }}</span></a></li>
  {%- endfor -%}
</ul>

{% for tag in tags %}
<section class="tag-section" id="{{ tag[0] | slugify }}">
  <h2>#{{ tag[0] }}</h2>
  <ul>
    {%- for post in tag[1] -%}
    <li>
      <a href="{{ post.url | relative_url }}">{{ post.title | escape }}</a>
      <span class="post-meta">· {{ post.date | date: "%b %-d, %Y" }}</span>
    </li>
    {%- endfor -%}
  </ul>
</section>
{% endfor %}
