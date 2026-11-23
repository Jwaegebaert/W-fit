using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace WFit.Api.Data.Migrations
{
    /// <inheritdoc />
    public partial class MuscleFocus : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "MuscleFocusJson",
                table: "Profiles",
                type: "nvarchar(2000)",
                maxLength: 2000,
                nullable: false,
                defaultValue: "{}");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "MuscleFocusJson",
                table: "Profiles");
        }
    }
}
