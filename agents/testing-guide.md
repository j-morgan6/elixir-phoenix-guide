# Testing Guide for Elixir/Phoenix

> **Reference companion to `elixir-phoenix-guide:testing-essentials`** — invoke the skill before writing any test file. This doc provides detailed examples; the skill provides the rules and workflow.

## Test Structure

```elixir
defmodule MyApp.MediaTest do
  use MyApp.DataCase, async: true

  alias MyApp.Media

  describe "images" do
    test "list_images/0 returns all images" do
      image = insert_image()
      assert Media.list_images() == [image]
    end

    test "create_image/1 with valid data creates an image" do
      attrs = valid_image_attributes()
      assert {:ok, %Image{} = image} = Media.create_image(attrs)
      assert image.title == attrs.title
    end
  end
end
```

## Testing Contexts

```elixir
defmodule MyApp.MediaTest do
  use MyApp.DataCase

  alias MyApp.Media
  alias MyApp.Media.Image

  describe "list_images/0" do
    test "returns all images" do
      image1 = insert_image(title: "First")
      image2 = insert_image(title: "Second")

      images = Media.list_images()

      assert length(images) == 2
      assert Enum.any?(images, & &1.id == image1.id)
      assert Enum.any?(images, & &1.id == image2.id)
    end

    test "returns empty list when no images exist" do
      assert Media.list_images() == []
    end
  end

  describe "create_image/1" do
    test "with valid attributes creates image" do
      attrs = %{
        title: "Test Image",
        filename: "test.jpg",
        file_path: "/uploads/test.jpg",
        content_type: "image/jpeg",
        file_size: 1024
      }

      assert {:ok, %Image{} = image} = Media.create_image(attrs)
      assert image.title == "Test Image"
      assert image.filename == "test.jpg"
    end

    test "with invalid attributes returns error changeset" do
      attrs = %{title: ""}

      assert {:error, %Ecto.Changeset{}} = Media.create_image(attrs)
    end
  end

  describe "update_image/2" do
    test "with valid attributes updates image" do
      image = insert_image()
      attrs = %{title: "Updated Title"}

      assert {:ok, %Image{} = updated} = Media.update_image(image, attrs)
      assert updated.title == "Updated Title"
    end
  end

  describe "delete_image/1" do
    test "deletes the image" do
      image = insert_image()

      assert {:ok, %Image{}} = Media.delete_image(image)
      assert_raise Ecto.NoResultsError, fn -> Media.get_image!(image.id) end
    end
  end

  # Test helpers
  defp insert_image(attrs \\ %{}) do
    defaults = %{
      title: "Test Image",
      filename: "test.jpg",
      file_path: "/uploads/test.jpg",
      content_type: "image/jpeg",
      file_size: 1024
    }

    {:ok, image} =
      defaults
      |> Map.merge(attrs)
      |> Media.create_image()

    image
  end
end
```

## Testing LiveViews

```elixir
defmodule MyAppWeb.GalleryLiveTest do
  use MyAppWeb.ConnCase
  import Phoenix.LiveViewTest

  alias MyApp.Media

  describe "Index" do
    test "displays all images", %{conn: conn} do
      image = insert_image(title: "Sunset")

      {:ok, _lv, html} = live(conn, "/gallery")

      assert html =~ "Sunset"
    end

    test "uploads new image", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/gallery")

      image =
        file_input(lv, "#upload-form", :image, [
          %{
            name: "test.png",
            content: File.read!("test/support/fixtures/test.png"),
            type: "image/png"
          }
        ])

      assert render_upload(image, "test.png") =~ "100%"

      html =
        lv
        |> form("#upload-form", image: %{title: "Test Upload"})
        |> render_submit()

      assert html =~ "Test Upload"
    end

    test "deletes image", %{conn: conn} do
      image = insert_image(title: "To Delete")

      {:ok, lv, _html} = live(conn, "/gallery")

      html =
        lv
        |> element("#image-#{image.id} button", "Delete")
        |> render_click()

      refute html =~ "To Delete"
    end

    test "creates folder", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/gallery")

      html =
        lv
        |> form("#folder-form", folder: %{name: "Vacation"})
        |> render_submit()

      assert html =~ "Vacation"
    end

    test "moves image to folder", %{conn: conn} do
      image = insert_image()
      folder = insert_folder(name: "Vacation")

      {:ok, lv, _html} = live(conn, "/gallery")

      lv
      |> element("#image-#{image.id} form")
      |> render_change(%{folder_id: folder.id})

      lv
      |> element("#image-#{image.id} form")
      |> render_submit()

      assert Media.get_image!(image.id).folder_id == folder.id
    end
  end

  describe "navigation" do
    test "navigates to folder view", %{conn: conn} do
      folder = insert_folder(name: "Vacation")

      {:ok, lv, _html} = live(conn, "/gallery")

      {:ok, _lv, html} =
        lv
        |> element("#folder-#{folder.id}")
        |> render_click()
        |> follow_redirect(conn, "/gallery/folder/#{folder.id}")

      assert html =~ "Vacation"
    end
  end
end
```

## Testing Schemas and Changesets

```elixir
defmodule MyApp.Media.ImageTest do
  use MyApp.DataCase

  alias MyApp.Media.Image

  describe "changeset/2" do
    test "valid attributes" do
      attrs = %{
        title: "Test",
        filename: "test.jpg",
        file_path: "/uploads/test.jpg",
        content_type: "image/jpeg",
        file_size: 1024
      }

      changeset = Image.changeset(%Image{}, attrs)

      assert changeset.valid?
    end

    test "requires title" do
      attrs = %{filename: "test.jpg"}

      changeset = Image.changeset(%Image{}, attrs)

      refute changeset.valid?
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates title length" do
      attrs = %{title: String.duplicate("a", 256)}

      changeset = Image.changeset(%Image{}, attrs)

      refute changeset.valid?
      assert %{title: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "validates file_size is positive" do
      attrs = %{file_size: -1}

      changeset = Image.changeset(%Image{}, attrs)

      refute changeset.valid?
      assert %{file_size: ["must be greater than 0"]} = errors_on(changeset)
    end
  end
end
```

## Test Helpers

Create helper functions in `test/support/`:

```elixir
defmodule MyApp.MediaFixtures do
  @moduledoc """
  Fixtures for Media context.
  """

  alias MyApp.Media

  def unique_image_title, do: "Image #{System.unique_integer([:positive])}"

  def valid_image_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      title: unique_image_title(),
      filename: "test.jpg",
      file_path: "/uploads/test.jpg",
      content_type: "image/jpeg",
      file_size: 1024
    })
  end

  def image_fixture(attrs \\ %{}) do
    {:ok, image} =
      attrs
      |> valid_image_attributes()
      |> Media.create_image()

    image
  end

  def folder_fixture(attrs \\ %{}) do
    {:ok, folder} =
      Enum.into(attrs, %{name: "Folder #{System.unique_integer()}"})
      |> Media.create_folder()

    folder
  end
end
```

## Async Tests

Tests can run concurrently when they don't share state:

```elixir
use MyApp.DataCase, async: true  # Safe - each test gets own sandbox

test "creates image", %{conn: conn} do
  # This test is isolated
end
```

Don't use `async: true` when:
- Tests modify global state
- Tests interact with external services
- Tests require specific test order

## Mocking

Use Mox for mocking:

```elixir
# In test/support/mocks.ex
Mox.defmock(MyApp.StorageMock, for: MyApp.Storage.Behaviour)

# In test
import Mox

test "uploads file" do
  expect(MyApp.StorageMock, :upload, fn _file ->
    {:ok, "/uploads/test.jpg"}
  end)

  # Test code that calls Storage.upload/1
end
```

## Testing Ecto Queries

```elixir
test "filters images by folder" do
  folder = insert_folder()
  image1 = insert_image(folder_id: folder.id)
  image2 = insert_image()  # No folder

  images = Media.list_images_by_folder(folder.id)

  assert length(images) == 1
  assert hd(images).id == image1.id
end
```

## Testing File Uploads in LiveView

```elixir
test "validates upload file types", %{conn: conn} do
  {:ok, lv, _html} = live(conn, "/gallery")

  # Try uploading invalid file type
  image =
    file_input(lv, "#upload-form", :image, [
      %{name: "test.pdf", content: "fake pdf", type: "application/pdf"}
    ])

  # Should show error
  assert render(lv) =~ "You have selected an unacceptable file type"
end

test "validates upload file size", %{conn: conn} do
  {:ok, lv, _html} = live(conn, "/gallery")

  large_content = :crypto.strong_rand_bytes(11_000_000)

  image =
    file_input(lv, "#upload-form", :image, [
      %{name: "large.jpg", content: large_content, type: "image/jpeg"}
    ])

  assert render(lv) =~ "Too large"
end
```

## Common Assertions

```elixir
# Equality
assert value == expected

# Pattern matching
assert {:ok, %Image{}} = result

# Presence
assert value
refute value

# Raise/throw
assert_raise ArgumentError, fn -> dangerous_function() end

# Database
assert Repo.get(Image, id)
assert Repo.aggregate(Image, :count) == 1

# In list
assert image in images
assert Enum.member?(images, image)

# HTML content (in tests)
assert html =~ "Expected text"
assert has_element?(lv, "#element-id")

# Flash messages
assert lv |> render() =~ "Successfully created"
```

## Test Organization

```
test/
├── my_app/
│   ├── media_test.exs          # Context tests
│   └── media/
│       ├── image_test.exs       # Schema tests
│       └── folder_test.exs
├── my_app_web/
│   ├── live/
│   │   └── gallery_live_test.exs
│   └── controllers/
│       └── page_controller_test.exs
├── support/
│   ├── conn_case.ex
│   ├── data_case.ex
│   ├── fixtures/
│   │   └── test.png
│   └── fixtures.ex              # Fixture helpers
└── test_helper.exs
```
