-- Reference data only. No users, stories or demo content are created here.
insert into public.genres (id, name, sort_order) values
  ('fantasy',       'Fantasy',       1),
  ('sci-fi',        'Sci-Fi',        2),
  ('slice-of-life', 'Slice of Life', 3),
  ('mystery',       'Mystery',       4),
  ('romance',       'Romance',       5),
  ('horror',        'Horror',        6),
  ('adventure',     'Adventure',     7)
on conflict (id) do nothing;
