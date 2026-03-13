import Ecto.Query

alias PhoenixKit.Modules.Comments
alias PhoenixKit.Modules.Posts.Post
alias PhoenixKit.RepoHelper
alias PhoenixKit.Users.Auth.User

repo = RepoHelper.repo()

# Get first user and first post from DB
user = repo.one!(from u in User, limit: 1)
post = repo.one!(from p in Post, limit: 1)

IO.puts("Using user: #{user.uuid}")
IO.puts("Using post: #{post.uuid}")

# Top-level comments
{:ok, c1} =
  Comments.create_comment("post", post.uuid, user.uuid, %{
    content: "This is a great article! Really enjoyed reading it."
  })

IO.puts("Created top-level comment 1: #{c1.uuid}")

{:ok, c2} =
  Comments.create_comment("post", post.uuid, user.uuid, %{
    content: "Thanks for sharing this information."
  })

IO.puts("Created top-level comment 2: #{c2.uuid}")

# Replies to c1
{:ok, r1} =
  Comments.create_comment("post", post.uuid, user.uuid, %{
    content: "I agree, very well written!",
    parent_uuid: c1.uuid
  })

IO.puts("Created reply 1 (depth 1): #{r1.uuid}")

{:ok, r2} =
  Comments.create_comment("post", post.uuid, user.uuid, %{
    content: "The part about configuration was especially helpful.",
    parent_uuid: c1.uuid
  })

IO.puts("Created reply 2 (depth 1): #{r2.uuid}")

# Nested reply to r1
{:ok, r3} =
  Comments.create_comment("post", post.uuid, user.uuid, %{
    content: "Absolutely, that section cleared up a lot of confusion for me.",
    parent_uuid: r1.uuid
  })

IO.puts("Created nested reply (depth 2): #{r3.uuid}")

IO.puts("\nDone! Created 5 test comments (2 top-level, 2 replies, 1 nested reply)")
